import Foundation
import CoreBluetooth
import AVFoundation

/// A recording, on the ring and/or downloaded to the phone.
struct Rec: Identifiable, Equatable {
    let id: String          // unix seconds, from amsg_<id>_mono.*
    let name: String        // amsg_<id>_mono.opus
    let size: Int64         // -1 = unknown
    let durationMs: Int?
    let onRing: Bool
    let savedLocal: Bool
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let unmapped: Bool
}

struct DiscoveredRing: Identifiable, Equatable {
    let id: UUID
    var name: String?
    var rssi: Int
    var systemConnected: Bool
}

enum RingUUID {
    static let svc = CBUUID(string: "B75497DB-806E-42B1-9E60-5871CA2E504B")
    static let auth = CBUUID(string: "B75497DE-806E-42B1-9E60-5871CA2E504B")
    static let ctrlW = CBUUID(string: "B75497DC-806E-42B1-9E60-5871CA2E504B")
    static let ctrlN = CBUUID(string: "B75497DD-806E-42B1-9E60-5871CA2E504B")
    static let dsvc = CBUUID(string: "E49A3001-F69A-11E8-8EB2-F2801F1B9FD1")
    static let dataN = CBUUID(string: "E49A3003-F69A-11E8-8EB2-F2801F1B9FD1")
}

/// iOS port of the Android `RingEngine` facade. One observable object holds all
/// state; the logic is split across extensions:
///  - RingEngine+Protocol: AA55 framing, HMAC auth, telemetry
///  - RingEngine+Library:  recordings list, downloads, persisted index
///  - RingEngine+Gestures: button input (0x26 stream, single click)
///  - OpusAudio:           decoding + playback
final class RingEngine: ObservableObject {
    // MARK: UI state
    @Published var status = "disconnected"
    @Published var connected = false          // authenticated
    @Published var active = false             // connecting or up
    @Published var model = ""
    @Published var fw = ""
    @Published var hw = ""
    @Published var battPct = -1
    @Published var battVolt = 0
    @Published var battSt = 0
    @Published var rssiHost = 0
    @Published var storFree: Int64 = -1
    @Published var storTot: Int64 = 0
    @Published var eventText = ""
    @Published var gestureText = ""
    @Published var library: [Rec] = []
    @Published var logs: [LogLine] = []
    @Published var toastText: String?
    @Published var downloading = false
    @Published var downloadingName: String?
    @Published var playingId: String?
    @Published var discovered: [DiscoveredRing] = []
    @Published var btState: CBManagerState = .unknown
    @Published var mediaToggle = false {
        didSet { log("play/pause " + (mediaToggle ? "ON" : "OFF")) }
    }

    // MARK: config (persisted)
    let defaults = UserDefaults.standard
    @Published var ringId: UUID? {
        didSet { defaults.set(ringId?.uuidString, forKey: "ringId") }
    }
    @Published var ringName: String {
        didSet { defaults.set(ringName, forKey: "ringName") }
    }
    @Published var bindKey: String {
        didSet { Keychain.set("bindKey", bindKey) }
    }
    @Published var userId: String {
        didSet { Keychain.set("userId", userId) }
    }
    /// Optional manual MAC (AA:BB:CC:DD:EE:FF). iOS hides the MAC, so normally it is
    /// derived from the ring's 0x80 device-info frame and verified against its HMAC.
    @Published var macOverride: String {
        didSet { defaults.set(macOverride, forKey: "macOverride") }
    }
    /// The MAC that last verified the ring's challenge.
    @Published var verifiedMac: String {
        didSet { defaults.set(verifiedMac, forKey: "mac") }
    }
    @Published var sn: String {
        didSet { defaults.set(sn, forKey: "sn") }
    }
    var fwid: String {
        didSet { defaults.set(fwid, forKey: "fwid") }
    }

    var isConfigured: Bool { ringId != nil }
    var hasCredentials: Bool { !bindKey.isEmpty && !userId.isEmpty }

    // MARK: protocol state
    let transport = BLETransport()
    var seq = 1
    var step = 0
    var macCandidates: [String] = []

    // MARK: library state
    var files: [String: Int] = [:]
    var collecting: [String: Int]?
    var durById: [String: Int] = [:]
    var jsonQ: [String] = []
    var autoJson = false
    var fileBuf = Data()
    var curFile: String?
    var recDebounce: DispatchWorkItem?

    // MARK: hooks for the AI layer
    var autoQueue: [String] = []
    /// The last new recording the ring announced (0x13), for the ring-mic talk turn.
    var lastAnnounced: (name: String, at: Date)?
    var shouldAutoDownload: () -> Bool = { false }
    var onDownloaded: (String) -> Void = { _ in }       // recording id, .opus saved
    var onDeletedLocal: (String) -> Void = { _ in }     // recording id
    var onGestureEvent: (String) -> Void = { _ in }     // "SINGLE", "DOUBLE", "HOLD"

    // MARK: gesture state
    var lastC26 = -1
    var lastT26: TimeInterval = 0
    var pressing = false
    var pendingSingle = false
    var pressStart: TimeInterval = 0
    var lastTickT: TimeInterval = 0
    var pressTicks = 0
    var releaseTask: DispatchWorkItem?
    var singleTask: DispatchWorkItem?
    var lastMediaKey: TimeInterval = 0

    // MARK: audio
    var player: AVAudioPlayer?
    var playerDelegate: PlayerDelegate?

    private var toastToken = 0
    private let tsFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        ringId = defaults.string(forKey: "ringId").flatMap(UUID.init(uuidString:))
        ringName = defaults.string(forKey: "ringName") ?? ""
        bindKey = Keychain.get("bindKey")
        userId = Keychain.get("userId")
        macOverride = defaults.string(forKey: "macOverride") ?? ""
        verifiedMac = defaults.string(forKey: "mac") ?? ""
        sn = defaults.string(forKey: "sn") ?? ""
        fwid = defaults.string(forKey: "fwid") ?? ""
        wireTransport()
        refreshLibrary()
    }

    // MARK: ring selection
    func selectRing(_ r: DiscoveredRing) {
        if ringId != r.id {
            // different ring: forget per-ring identity
            verifiedMac = ""
            sn = ""
            fwid = ""
        }
        ringId = r.id
        ringName = r.name ?? "Ring"
        log("ring selected: \(ringName) \(r.id.uuidString)")
    }

    func forgetRing() {
        if active { transport.disconnect() }
        ringId = nil
        ringName = ""
        verifiedMac = ""
        sn = ""
        fwid = ""
    }

    func startPickerScan() {
        discovered = []
        transport.startPickerScan()
    }

    func stopPickerScan() {
        transport.stopPickerScan()
    }

    // MARK: outputs
    func log(_ m: String) { logRaw(m, unmapped: false) }

    func logRaw(_ m: String, unmapped: Bool) {
        let line = tsFmt.string(from: Date()) + "  " + m
        #if DEBUG
        print("[VoxLibre] " + m)
        #endif
        logs.append(LogLine(text: line, unmapped: unmapped))
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    func toast(_ s: String) {
        toastToken += 1
        let t = toastToken
        toastText = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toastToken == t { self?.toastText = nil }
        }
    }

    func clearLogs() { logs.removeAll() }
}
