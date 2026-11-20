import Foundation
import MediaPlayer

/// Ring button input (port of RingGestures.java).
///  - the 0x26 press stream (a repeating counter while held) → PRESSED / SINGLE /
///    DOUBLE / HOLD — a monitor only;
///  - a single click (0xf0 / 0x15) optionally toggles playback.
///
/// iOS can't inject a system-wide media key like Android's AudioManager does, so the
/// toggle controls the system Music app player (Apple Music / local library).
extension RingEngine {
    private static let holdMs = 0.7, doubleMs = 0.4, releaseMs = 0.3

    func resetGestures() {
        lastC26 = -1
        pressing = false
        pendingSingle = false
        releaseTask?.cancel()
        singleTask?.cancel()
    }

    func feed26(_ val: Int) {
        let now = Date().timeIntervalSince1970
        var extra = ""
        if lastC26 >= 0 {
            var dv = val - lastC26
            if dv < 0 { dv += 256 }
            let dt = Int((now - lastT26) * 1000)
            let hz = dt > 0 ? 1000.0 / Double(dt) : 0
            extra = " Δ=\(dv) dt=\(dt)ms ~" + String(format: "%.1f", hz) + "Hz"
        }
        lastC26 = val
        lastT26 = now
        log("RX [ctrl] op=0x26 val=\(val) (0x\(String(val, radix: 16)))\(extra)")
        trackPress(now)
    }

    private func trackPress(_ t: TimeInterval) {
        if !pressing {
            pressing = true
            pressStart = t
            pressTicks = 0
            gestureText = "button: PRESSED…"
        }
        pressTicks += 1
        lastTickT = t
        releaseTask?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onRelease() }
        releaseTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseMs, execute: w)
    }

    private func onRelease() {
        pressing = false
        let dur = lastTickT - pressStart
        if dur >= Self.holdMs {
            pendingSingle = false
            onGesture("HOLD", "(\(Int(dur * 1000))ms, \(pressTicks) ticks)")
        } else if pendingSingle {
            pendingSingle = false
            singleTask?.cancel()
            onGesture("DOUBLE", nil)
        } else {
            pendingSingle = true
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.pendingSingle else { return }
                self.pendingSingle = false
                self.onGesture("SINGLE", nil)
            }
            singleTask = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleMs, execute: w)
        }
    }

    private func onGesture(_ type: String, _ detail: String?) {
        log("GESTURE(0x26): \(type)" + (detail.map { " " + $0 } ?? ""))
        gestureText = "Last gesture: \(type)" + (detail.map { "  " + $0 } ?? "")
        onGestureEvent(type)
    }

    /// A single click (0xf0 / 0x15): toggle Music playback when the feature is enabled.
    func singleClick() {
        guard mediaToggle else {
            log("single click (play/pause feature off)")
            return
        }
        let now = Date().timeIntervalSince1970
        if now - lastMediaKey < 0.4 {
            log("click ignored (debounce)")
            return
        }
        lastMediaKey = now
        let mp = MPMusicPlayerController.systemMusicPlayer
        if mp.playbackState == .playing {
            mp.pause()
            log("PAUSE sent to Music (single click)")
        } else {
            mp.play()
            log("PLAY sent to Music (single click)")
        }
    }
}
