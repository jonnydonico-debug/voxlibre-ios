import Foundation
import AVFoundation

final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onEnd: () -> Void = {}
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) { onEnd() }
}

extension RingEngine {
    /// Decode (off the main thread) if needed, then play.
    func play(_ r: Rec) {
        let src = localURL(r.name)
        guard FileManager.default.fileExists(atPath: src.path) else { toast("download first"); return }
        let wav = wavURL(r.id)
        if FileManager.default.fileExists(atPath: wav.path) {
            playWav(wav, id: r.id)
            return
        }
        toast("decoding…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let pcm = try OpusAudio.decode(try Data(contentsOf: src))
                try OpusAudio.writeWav(pcm, to: wav)
                DispatchQueue.main.async {
                    self?.log("decoded \(r.name) (\(pcm.count) samples / "
                              + String(format: "%.2f", Double(pcm.count) / OpusAudio.sampleRate) + "s)")
                    self?.playWav(wav, id: r.id)
                    self?.refreshLibrary()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.log("decode failed: \(error.localizedDescription)")
                    self?.toast("decode failed")
                }
            }
        }
    }

    func stopPlay() {
        player?.stop()
        player = nil
        playingId = nil
    }

    private func playWav(_ url: URL, id: String) {
        do {
            stopPlay()
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            let del = PlayerDelegate()
            del.onEnd = { [weak self] in
                self?.log("play end")
                self?.playingId = nil
            }
            playerDelegate = del
            p.delegate = del
            p.play()
            player = p
            playingId = id
            log("playing \(url.lastPathComponent)")
        } catch {
            log("play failed: \(error.localizedDescription)")
            toast("not playable")
        }
    }

    /// URL to share/export: the decoded WAV if present, else the raw .opus.
    func shareURL(_ r: Rec) -> URL? {
        let wav = wavURL(r.id)
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        let src = localURL(r.name)
        return FileManager.default.fileExists(atPath: src.path) ? src : nil
    }
}
