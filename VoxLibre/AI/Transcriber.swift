import Foundation
import AVFoundation
import Speech

/// On-device transcription of a recording (Apple SpeechAnalyzer, iOS 26+). Free, private,
/// works offline once the language model is installed. Returns phrase-level segments with
/// timestamps; it doesn't separate speakers (Claude labels them afterwards).
enum Transcriber {
    enum Failure: LocalizedError {
        case unsupported(String), unavailable
        var errorDescription: String? {
            switch self {
            case .unsupported(let l): return "On-device transcription doesn't support \(l)."
            case .unavailable: return "On-device transcription isn't available on this device."
            }
        }
    }

    static func transcribe(_ wav: URL, locale: Locale = .current) async throws -> [Segment] {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupported(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        // First use of a language downloads its model (once, managed by iOS).
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: wav)

        let collector = Task { () throws -> [Segment] in
            var out: [Segment] = []
            for try await r in transcriber.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(Segment(start: r.range.start.seconds.finiteOrZero,
                                   end: r.range.end.seconds.finiteOrZero, text: text, speaker: nil))
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}

extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
