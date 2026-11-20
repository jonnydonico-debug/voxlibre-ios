import Foundation
import AVFoundation
import Speech

/// Voice in and out for the agent chat.
///  - Listening: on-device speech recognition from the current mic (AirPods when connected),
///    ending automatically after a short pause.
///  - Speaking: the reply is read sentence by sentence while it is still streaming in.
///    The audio session switches to playback while speaking so AirPods use their
///    high-quality (A2DP) profile rather than the call (HFP) profile.
final class VoiceIO: NSObject, ObservableObject {
    enum State { case idle, listening, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var partial = ""
    @Published var lastError: String?

    private let settings: AISettings
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?
    private var listenCont: CheckedContinuation<String?, Never>?

    private var buffer = ""
    private var streamOpen = false
    private var pending = 0
    private var speakCont: CheckedContinuation<Void, Never>?

    init(settings: AISettings) {
        self.settings = settings
        super.init()
        synth.delegate = self
    }

    // MARK: listening
    func authorize() async -> Bool {
        let s = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard s == .authorized else {
            lastError = "Speech recognition is off — allow it in Settings › VoxLibre."
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off — allow it in Settings › VoxLibre."
            return false
        }
        return true
    }

    /// Listens for one utterance. Returns nil if nothing was said (or it was cancelled).
    @MainActor
    func listen() async -> String? {
        stopSpeaking()
        lastError = nil
        guard await authorize() else { return nil }
        recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition isn't available right now."
            return nil
        }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try s.setActive(true)
        } catch {
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            return nil
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            lastError = "No microphone available."
            return nil
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            return nil
        }

        partial = ""
        state = .listening
        return await withCheckedContinuation { cont in
            listenCont = cont
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.listenCont != nil else { return }
                    if let r = result {
                        self.partial = r.bestTranscription.formattedString
                        if r.isFinal { self.finishListening(self.partial); return }
                        self.armSilence(1.4)  // a short pause ends the turn
                    }
                    if error != nil { self.finishListening(self.partial) }
                }
            }
            armSilence(8)  // nothing said at all → give up
        }
    }

    func cancelListening() { finishListening(nil) }

    private func armSilence(_ s: TimeInterval) {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.finishListening(self.partial)
        }
    }

    private func finishListening(_ text: String?) {
        guard let cont = listenCont else { return }
        listenCont = nil
        silence?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        state = .idle
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cont.resume(returning: t.isEmpty ? nil : t)
    }

    // MARK: speaking
    /// Start a spoken reply; feed text deltas as they stream, then `finish()`.
    func beginSpeaking() {
        buffer = ""
        streamOpen = true
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try s.setActive(true)
        } catch {
            lastError = "Audio: \(error.localizedDescription)"
        }
    }

    func feed(_ delta: String) {
        guard streamOpen else { return }
        buffer += delta
        while let cut = Self.sentenceEnd(in: buffer) {
            speak(String(buffer[..<cut]))
            buffer = String(buffer[cut...])
        }
    }

    /// Ends the reply and waits until everything has been spoken.
    @MainActor
    func finish() async {
        guard streamOpen else { return }
        streamOpen = false
        speak(buffer)
        buffer = ""
        if pending > 0 {
            await withCheckedContinuation { speakCont = $0 }
        }
        deactivate()
    }

    func stopSpeaking() {
        streamOpen = false
        buffer = ""
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        pending = 0
        speakCont?.resume()
        speakCont = nil
        if state == .speaking { state = .idle }
    }

    /// Say one complete piece of text (not streamed).
    @MainActor
    func say(_ text: String) async {
        beginSpeaking()
        feed(text)
        await finish()
    }

    private func speak(_ raw: String) {
        let text = Self.plain(raw)
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = Float(settings.speechRate)
        pending += 1
        state = .speaking
        synth.speak(u)
    }

    private func deactivate() {
        if state == .speaking { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var voice: AVSpeechSynthesisVoice? {
        if !settings.voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: settings.voiceId) { return v }
        return Self.voices.first
    }

    /// Voices for the current language, best quality first.
    static var voices: [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue
                                                                 : $0.name < $1.name }
    }

    /// Index just past the first sentence end that is followed by whitespace.
    static func sentenceEnd(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\n" { return next }
            if ".!?".contains(c), next < s.endIndex, s[next].isWhitespace { return next }
            i = next
        }
        return nil
    }

    /// Strip markdown so it isn't read aloud.
    static func plain(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*([-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension VoiceIO: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { utteranceDone() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { utteranceDone() }

    private func utteranceDone() {
        DispatchQueue.main.async {
            self.pending = max(0, self.pending - 1)
            if self.pending == 0 && !self.streamOpen {
                if self.state == .speaking { self.state = .idle }
                self.speakCont?.resume()
                self.speakCont = nil
            }
        }
    }
}
