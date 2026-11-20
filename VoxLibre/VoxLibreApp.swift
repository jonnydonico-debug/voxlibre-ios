import SwiftUI
import UIKit

/// Owns the long-lived objects and wires them together.
final class AppModel {
    static let shared = AppModel()

    let engine = RingEngine()
    let settings = AISettings()
    let memory = MemoryStore()
    let notes: NotesStore
    let voice: VoiceIO
    let agent: ChatAgent

    private init() {
        notes = NotesStore(memory: memory, settings: settings)
        voice = VoiceIO(settings: settings)
        agent = ChatAgent(settings: settings, memory: memory, notes: notes, voice: voice)

        let e = engine, s = settings, n = notes, m = memory, a = agent
        n.log = { msg in DispatchQueue.main.async { e.log("[ai] " + msg) } }
        a.log = { msg in DispatchQueue.main.async { e.log("[agent] " + msg) } }
        e.shouldAutoDownload = { s.autoDownload || a.awaitingRingClip }
        e.onDownloaded = { id in
            let tookIt = MainActor.assumeIsolated { a.takeRingClip(id) }
            if !tookIt { n.process(id, analyze: s.autoAnalyze) }
        }
        e.onDeletedLocal = { id in
            n.delete(id)
            m.removeAll(source: id)
        }
        e.onGestureEvent = { g in
            guard s.voiceGesture == g else { return }
            Task { @MainActor in
                if s.requireHeadphones && !VoiceIO.headphonesConnected {
                    e.log("[agent] \(g) ignored: no headphones connected")
                    return
                }
                // The phone's mic can't start in the background, so "auto" uses the ring's mic then.
                let inBackground = UIApplication.shared.applicationState != .active
                let ringMic = s.talkMic == "ring" || (s.talkMic == "auto" && inBackground)
                if ringMic {
                    a.startRingTurn()
                    // The ring may have announced its clip just before the gesture was recognised.
                    if let last = e.lastAnnounced, Date().timeIntervalSince(last.at) < 5 {
                        e.fetchAnnounced(last.name)
                    }
                } else if a.conversationActive {
                    a.stop()
                } else {
                    a.startVoice()
                }
            }
        }
    }
}

@main
struct VoxLibreApp: App {
    private let m = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(m.engine)
                .environmentObject(m.settings)
                .environmentObject(m.memory)
                .environmentObject(m.notes)
                .environmentObject(m.voice)
                .environmentObject(m.agent)
                .preferredColorScheme(.dark)
                .tint(.lime)
        }
    }
}

extension Color {
    static let lime = Color(red: 0xA6 / 255, green: 0xE6 / 255, blue: 0x35 / 255)
    static let muted = Color(red: 0x9A / 255, green: 0xA0 / 255, blue: 0xA6 / 255)
    static let amber = Color(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)
    static let danger = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
    static let synced = Color(red: 0x7E / 255, green: 0xC8 / 255, blue: 0xFF / 255)
    static let panel = Color(white: 0.15)
}
