import Foundation
import CryptoKit

/// The Timon/URING wire protocol: AA55 framing, the nested HMAC auth handshake and
/// telemetry/device-status decoding (port of RingProtocol.java).
extension RingEngine {
    static let knownCtrl: Set<Int> = [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                                      0x25, 0x26, 0x2a, 0x2d, 0x30, 0xf0, 0xf2, 0xfa]

    // MARK: transport wiring
    func wireTransport() {
        let t = transport
        t.log = { [weak self] in self?.log($0) }
        t.onBTState = { [weak self] in self?.btState = $0 }
        t.onDiscover = { [weak self] r in
            guard let self else { return }
            if let i = self.discovered.firstIndex(where: { $0.id == r.id }) {
                var cur = self.discovered[i]
                cur.rssi = r.rssi
                if r.name != nil { cur.name = r.name }
                cur.systemConnected = cur.systemConnected || r.systemConnected
                self.discovered[i] = cur
            } else {
                self.discovered.append(r)
            }
        }
        t.onConnected = { [weak self] in self?.status = "connected, negotiating…" }
        t.onAuthReady = { [weak self] in
            guard let self else { return }
            self.step = 0
            self.wAuth(0x82, [0x05], "proto")
        }
        t.onAuthFrame = { [weak self] v in self?.handleAuth(Self.frameOp(v), Self.frameData(v)) }
        t.onCtrlFrame = { [weak self] v in self?.handleCtrl(Self.frameOp(v), Self.frameData(v)) }
        t.onData = { [weak self] v in self?.onFileData(v) }
        t.onControlReady = { [weak self] in
            self?.log("ready: telemetry+list")
            self?.startTelemetry()
        }
        t.onDisconnected = { [weak self] in
            guard let self else { return }
            self.connected = false
            self.active = false
            self.status = "disconnected"
            self.resetGestures()
            self.onLibraryDisconnected()
            self.refreshLibrary()
        }
    }

    // MARK: connection
    func toggleConnect() {
        if !active {
            guard let id = ringId else {
                toast("select a ring first")
                status = "disconnected"
                return
            }
            guard hasCredentials else {
                toast("enter BIND KEY and USER ID in Settings")
                status = "disconnected"
                return
            }
            active = true
            status = "connecting…"
            log("=== connecting \(ringName) ===")
            transport.connect(id)
        } else {
            log("disconnecting")
            transport.disconnect()
        }
    }

    // MARK: framing / crypto
    // AA55 frame: [AA][55][seqHi][seqLo][lenHi][lenLo][op][payload…][chk][0D][0A]
    func enc(_ op: UInt8, _ d: [UInt8]) -> Data {
        seq = (seq + 1) & 0xFFFF
        if seq == 0 { seq = 1 }
        let ln = d.count + 1
        var f: [UInt8] = [0xAA, 0x55, UInt8(seq >> 8), UInt8(seq & 0xFF),
                          UInt8((ln >> 8) & 0xFF), UInt8(ln & 0xFF), op]
        f += d
        f += [0, 0x0D, 0x0A]
        return Data(f)
    }

    static func frameOp(_ v: [UInt8]) -> Int { v.count >= 7 ? Int(v[6]) : -1 }

    static func frameData(_ v: [UInt8]) -> [UInt8] {
        guard v.count >= 10 else { return [] }
        let ln = (Int(v[4]) << 8 | Int(v[5])) - 1
        let end = min(7 + max(ln, 0), v.count)
        return Array(v[7..<end])
    }

    static func hex<S: Sequence>(_ a: S) -> String where S.Element == UInt8 {
        a.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacHex(_ k: String, _ m: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(m.utf8), using: SymmetricKey(data: Data(k.utf8)))
        return hex(Data(mac))
    }

    private var kh: String { Self.hex(Array(bindKey.utf8)) }

    private func content(_ mac: String, _ n: String) -> String { "\(fwid)_\(sn)_\(mac)_\(n)" }

    func wAuth(_ op: UInt8, _ d: [UInt8], _ lb: String) {
        // The USER ID (0x81) and the signed answer to the ring's challenge are account
        // secrets, so they're never written to the log (which can be shared).
        let secret = op == 0x81 || (op == 0x82 && d.first == 3)
        log("TX [auth] op=0x\(String(op, radix: 16)) \(lb) " + (secret ? "[\(d.count) bytes hidden]" : Self.hex(d)))
        transport.writeAuth(enc(op, d))
    }

    func wCtrl(_ op: UInt8, _ d: [UInt8], _ lb: String) {
        log("TX [ctrl] op=0x\(String(op, radix: 16)) \(lb)")
        transport.writeCtrl(enc(op, d))
    }

    func startTelemetry() {
        wCtrl(0x30, [0x01], "init")
        wCtrl(0x25, [], "status")
        requestList()
        wCtrl(0x2a, [0, 0], "telemetry")
    }

    // MARK: outbound file commands
    func sendList() { wCtrl(0x11, [], "list") }

    func sendRead(_ name: String) {
        let nm = Array(name.utf8)
        let d: [UInt8] = [1, UInt8(nm.count)] + nm + [0, 0, 0, 0, 0]
        wCtrl(0x12, d, "read \(name)")
    }

    func sendDelete(_ name: String) {
        let nm = Array(name.utf8)
        wCtrl(0x17, [0x02, UInt8(nm.count)] + nm, "delete \(name)")
    }

    // MARK: device info (0x80)
    /// 0x80: [snLen][SN][macLen][MAC rev][fwLen][FWID]
    func parseDeviceInfo(_ d: [UInt8]) {
        var o = 0
        guard o < d.count else { return }
        let snLen = Int(d[o]); o += 1
        guard o + snLen <= d.count else { return }
        sn = String(decoding: d[o..<o + snLen], as: UTF8.self)
        o += snLen
        if o < d.count {
            let macLen = Int(d[o]); o += 1
            let end = min(o + macLen, d.count)
            macCandidates = Self.macCandidates(Array(d[o..<end]))
            o += macLen
        }
        if o < d.count {
            let fwLen = Int(d[o]); o += 1
            if o + fwLen <= d.count { fwid = String(decoding: d[o..<o + fwLen], as: UTF8.self) }
        }
        log("device-info: SN=\(sn) FWID=\(fwid) MAC candidates=\(macCandidates.prefix(2).joined(separator: ", "))")
    }

    /// Android formats the MAC as "AA:BB:CC:DD:EE:FF". iOS can't read it, so build the
    /// plausible spellings from the bytes the ring reports; the HMAC on the ring's
    /// challenge tells us which one is right.
    static func macCandidates(_ b: [UInt8]) -> [String] {
        func fmt(_ x: [UInt8]) -> String { x.map { String(format: "%02X", $0) }.joined(separator: ":") }
        var out: [String] = []
        if b.count == 6 {
            out += [fmt(b.reversed()), fmt(b)]
        } else {
            let s = String(decoding: b, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            let hx = Array(s.filter(\.isHexDigit))
            if hx.count == 12 {
                let bytes = stride(from: 0, to: 12, by: 2).compactMap { UInt8(String(hx[$0...$0 + 1]), radix: 16) }
                if bytes.count == 6 { out += [fmt(bytes), fmt(bytes.reversed())] }
            }
            if !s.isEmpty { out.append(s) }
        }
        out += out.map { $0.lowercased() }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: auth handshake
    func handleAuth(_ op: Int, _ data: [UInt8]) {
        let challenge = op == 0x82 && data.first == 0x01
        log("RX [auth] op=0x\(String(op, radix: 16)) " + (challenge ? "[challenge, \(data.count) bytes hidden]" : Self.hex(data)))
        if op == 0x80 && data.count > 10 {
            parseDeviceInfo(data)
        }
        if op == 0x82, data.count >= 1, data[0] == 0x01 {
            let body = data.count > 2 ? String(decoding: data[2...], as: UTF8.self) : ""
            let p = body.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
            let nonce = p.first ?? ""
            let dauth = p.count > 1 ? p[1] : ""

            var cands: [String] = []
            let ov = macOverride.trimmingCharacters(in: .whitespaces)
            if !ov.isEmpty { cands.append(ov) }
            if !verifiedMac.isEmpty { cands.append(verifiedMac) }
            cands += macCandidates
            var seen = Set<String>()
            cands = cands.filter { seen.insert($0).inserted }

            let key = kh
            let match = cands.first { Self.hmacHex(key, content($0, nonce)) == dauth }
            let mac = match ?? cands.first ?? ""
            if let match {
                log("challenge verifyRing=true (mac \(match))")
                verifiedMac = match
            } else {
                log("challenge verifyRing=false — tried \(cands.count) MAC spellings. "
                    + "Check BIND KEY, or enter the ring's MAC in Settings › Advanced.")
            }

            let an = "app_" + nonce
            let inner = Self.hmacHex(key, an)
            let aa = Self.hmacHex(inner, content(mac, an))
            let anb = Array(an.utf8), aab = Array(aa.utf8)
            let pl: [UInt8] = [3, UInt8(anb.count)] + anb + [UInt8(ascii: "@")] + aab
            wAuth(0x82, pl, "app response")
            step = 99
            return
        }
        if step == 99, op == 0x82, data.count >= 1, data[0] == 0x03 {
            log("APP-AUTH ACCEPTED")
            connected = true
            status = "authenticated"
            refreshLibrary()
            transport.enableControlChannels()
            return
        }
        if step == 99, op == 0x82 {
            log("auth: unexpected reply (rejected?) — check BIND KEY / USER ID / MAC")
        }
        switch step {
        case 0:
            step = 1
            wAuth(0x80, [], "device info")
        case 1:
            let uid = Array(userId.utf8)
            step = 2
            wAuth(0x81, [3, UInt8(uid.count)] + uid, "userId")
        case 2:
            step = 3
            wAuth(0x82, [0x01], "request challenge")
        default:
            break
        }
    }

    // MARK: control channel
    private static func be32(_ d: [UInt8], _ o: Int) -> Int64 {
        Int64(d[o]) << 24 | Int64(d[o + 1]) << 16 | Int64(d[o + 2]) << 8 | Int64(d[o + 3])
    }

    func handleCtrl(_ op: Int, _ d: [UInt8]) {
        if op == 0x26, d.count >= 1 {
            feed26(Int(d[0]))
            return
        }
        logRaw("RX [ctrl] op=0x\(String(op, radix: 16)) \(Self.hex(d))", unmapped: !Self.knownCtrl.contains(op))
        switch op {
        case 0x14 where d.count >= 12:
            storFree = Self.be32(d, 0)
            storTot = Self.be32(d, 8)
        case 0xfa:
            let t = d.count >= 4 ? Self.be32(d, 0) : 0
            log("ring RTC = \(t)" + (t > 1_000_000_000 ? " (\(Date(timeIntervalSince1970: TimeInterval(t))))" : ""))
        case 0x2a:
            break // metric; battery comes from 0xf2
        case 0xf2 where d.count >= 12:
            hw = "\((d[1] >> 4) & 15).\(d[1] & 15).\(d[2])"
            fw = "\((d[3] >> 4) & 15).\(d[3] & 15)." + String(format: "%02d", d[4])
            battSt = Int(d[5])
            battPct = Int(d[6])
            rssiHost = 256 - Int(d[9])
            battVolt = Int(d[10]) << 8 | Int(d[11])
            if d.count > 14 {
                let ml = Int(d[14])
                if ml > 0, d.count >= 15 + ml {
                    model = String(bytes: d[15..<15 + ml], encoding: .isoLatin1) ?? model
                }
            }
        case 0xf0:
            let single = d.first == 0x01
            eventText = (single ? "Single click" : "Gesture 0xf0") + ": " + Self.hex(d)
            if single { singleClick() }
        case 0x15 where d.count >= 2:
            let code = Int(d[0])
            let pressed = d[1] != 0
            log("BUTTON(0x15) code=\(code) pressed=\(pressed)")
            if code == 0x01 && pressed { singleClick() }
        case 0x16:
            log("heartbeat(0x16)")
        case 0x18 where d.count >= 3:
            let code = Int(d[0]) << 8 | Int(d[1])
            var msg = ""
            if d.count > 5 {
                let ln = Int(d[3]) << 8 | Int(d[4])
                if ln > 0, d.count >= 5 + ln { msg = String(decoding: d[5..<5 + ln], as: UTF8.self) }
            }
            eventText = "FAULT(0x18) code=\(code)" + (msg.isEmpty ? "" : " " + msg)
            log("deviceFault code=\(code) \(msg)")
        case 0x11, 0x12, 0x13, 0x17:
            onLibraryCtrl(op, d)
        default:
            break
        }
    }
}
