import Foundation
import CoreBluetooth

/// CoreBluetooth transport (iOS counterpart of NordicTransport): connection,
/// notification subscriptions and a serialized write queue. Frames arrive raw;
/// writes take an already-encoded frame. Everything runs on the main queue.
///
/// iOS differences vs Android:
///  - no MAC addresses: rings are identified by the CBPeripheral UUID iOS assigns;
///  - no "bonded devices" list: the picker scans + lists system-connected peripherals;
///  - MTU is negotiated by iOS automatically; pairing (if the ring requires
///    encryption) is prompted by iOS on first protected access.
final class BLETransport: NSObject {
    var onBTState: (CBManagerState) -> Void = { _ in }
    var onConnected: () -> Void = {}
    var onAuthReady: () -> Void = {}
    var onAuthFrame: ([UInt8]) -> Void = { _ in }
    var onCtrlFrame: ([UInt8]) -> Void = { _ in }
    var onData: ([UInt8]) -> Void = { _ in }
    var onControlReady: () -> Void = {}
    var onDisconnected: () -> Void = {}
    var onDiscover: (DiscoveredRing) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var authCh, ctrlWCh, ctrlNCh, dataNCh: CBCharacteristic?
    private var pendingConnect: UUID?
    private var targetScan: UUID?
    private var pickerScan = false
    private var servicesPending = 0
    private var controlPending = 0
    private var writeQ: [(CBCharacteristic, Data)] = []
    private var writing = false
    private var timeout: DispatchWorkItem?
    private var linkUp = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    var state: CBManagerState { central.state }

    // MARK: connection
    func connect(_ id: UUID) {
        guard central.state == .poweredOn else {
            pendingConnect = id
            log("bluetooth not ready (state=\(central.state.rawValue)); will connect when on")
            return
        }
        pendingConnect = nil
        armTimeout()
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(p)
        } else if let p = central.retrieveConnectedPeripherals(withServices: [RingUUID.svc])
                    .first(where: { $0.identifier == id }) {
            attach(p)
        } else {
            log("ring not known to iOS yet; scanning for it…")
            targetScan = id
            central.scanForPeripherals(withServices: nil)
        }
    }

    func disconnect() {
        pendingConnect = nil
        stopTargetScan()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
            if p.state != .connected { finish() }  // was still connecting
        } else {
            finish()
        }
    }

    private func attach(_ p: CBPeripheral) {
        stopTargetScan()
        peripheral = p
        p.delegate = self
        log("connecting to \(p.name ?? "?") (\(p.identifier.uuidString))")
        central.connect(p)
    }

    private func armTimeout() {
        timeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.linkUp else { return }
            self.log("connect timeout (is the ring nearby and awake?)")
            self.disconnect()
        }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    }

    private func stopTargetScan() {
        targetScan = nil
        if !pickerScan && central.isScanning { central.stopScan() }
    }

    private func finish() {
        timeout?.cancel()
        let wasSomething = peripheral != nil || linkUp
        peripheral = nil
        authCh = nil; ctrlWCh = nil; ctrlNCh = nil; dataNCh = nil
        writeQ.removeAll()
        writing = false
        linkUp = false
        _ = wasSomething
        onDisconnected()
    }

    // MARK: picker
    func startPickerScan() {
        pickerScan = true
        guard central.state == .poweredOn else { return }
        for p in central.retrieveConnectedPeripherals(withServices: [RingUUID.svc]) {
            onDiscover(DiscoveredRing(id: p.identifier, name: p.name, rssi: 0, systemConnected: true))
        }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopPickerScan() {
        pickerScan = false
        if targetScan == nil && central.isScanning { central.stopScan() }
    }

    // MARK: writes
    func writeAuth(_ frame: Data) { if let c = authCh { enqueue(c, frame) } }
    func writeCtrl(_ frame: Data) { if let c = ctrlWCh { enqueue(c, frame) } }

    private func enqueue(_ c: CBCharacteristic, _ d: Data) {
        writeQ.append((c, d))
        pump()
    }

    private func pump() {
        guard !writing, let p = peripheral, !writeQ.isEmpty else { return }
        let (c, d) = writeQ.removeFirst()
        if c.properties.contains(.write) {
            writing = true
            p.writeValue(d, for: c, type: .withResponse)
        } else {
            p.writeValue(d, for: c, type: .withoutResponse)
            pump()
        }
    }

    /// After auth: subscribe CTRL-notify (+ DATA when present), then onControlReady.
    func enableControlChannels() {
        guard let p = peripheral, let cn = ctrlNCh else { return }
        controlPending = dataNCh != nil ? 2 : 1
        p.setNotifyValue(true, for: cn)
        if let dn = dataNCh { p.setNotifyValue(true, for: dn) }
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("bluetooth state=\(c.state.rawValue)")
        onBTState(c.state)
        if c.state == .poweredOn {
            if let id = pendingConnect { connect(id) }
            if pickerScan { startPickerScan() }
        } else if peripheral != nil {
            finish()
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        if pickerScan {
            onDiscover(DiscoveredRing(id: p.identifier, name: name, rssi: rssi.intValue, systemConnected: false))
        }
        if let t = targetScan, p.identifier == t {
            log("found ring while scanning (rssi \(rssi))")
            attach(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        linkUp = true
        timeout?.cancel()
        log("link up; discovering services")
        onConnected()
        p.discoverServices([RingUUID.svc, RingUUID.dsvc])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "?")")
        finish()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        finish()
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("service discovery error: \(error.localizedDescription)") }
        let svcs = p.services ?? []
        guard svcs.contains(where: { $0.uuid == RingUUID.svc }) else {
            log("service not found — is this the ring?")
            disconnect()
            return
        }
        servicesPending = svcs.count
        for s in svcs { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error { log("char discovery error: \(error.localizedDescription)") }
        for ch in s.characteristics ?? [] {
            switch ch.uuid {
            case RingUUID.auth: authCh = ch
            case RingUUID.ctrlW: ctrlWCh = ch
            case RingUUID.ctrlN: ctrlNCh = ch
            case RingUUID.dataN: dataNCh = ch
            default: break
            }
        }
        servicesPending -= 1
        guard servicesPending <= 0 else { return }
        guard let a = authCh, ctrlWCh != nil, ctrlNCh != nil else {
            log("required characteristics missing")
            disconnect()
            return
        }
        log("characteristics ready (data channel: \(dataNCh != nil ? "yes" : "no")); subscribing AUTH")
        p.setNotifyValue(true, for: a)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error {
            log("notify \(ch.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)")
            return
        }
        if ch.uuid == RingUUID.auth, ch.isNotifying {
            onAuthReady()
        } else if ch.uuid == RingUUID.ctrlN || ch.uuid == RingUUID.dataN {
            controlPending -= 1
            if controlPending == 0 { onControlReady() }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("rx error: \(error.localizedDescription)"); return }
        guard let v = ch.value else { return }
        let b = [UInt8](v)
        switch ch.uuid {
        case RingUUID.auth: onAuthFrame(b)
        case RingUUID.ctrlN: onCtrlFrame(b)
        case RingUUID.dataN: onData(b)
        default: break
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("write error: \(error.localizedDescription)") }
        writing = false
        pump()
    }
}
