import Foundation
import AVFoundation

/// Settings for the AI features. Secrets (Claude key, house agent token) live in the Keychain.
final class AISettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var apiKey: String { didSet { Keychain.set("claudeKey", apiKey) } }
    /// Optional house agent (smart-home assistant) the ring agent can hand jobs to.
    @Published var houseName: String { didSet { d.set(houseName, forKey: "houseName") } }
    @Published var houseURL: String { didSet { d.set(houseURL, forKey: "houseURL") } }
    @Published var houseToken: String { didSet { Keychain.set("houseToken", houseToken) } }
    /// The ring wearer's name, used to label them in transcripts.
    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }
    @Published var autoAnalyze: Bool { didSet { d.set(autoAnalyze, forKey: "autoAnalyze") } }
    @Published var autoDownload: Bool { didSet { d.set(autoDownload, forKey: "autoDownload") } }
    /// What each ring input does, keyed by gesture ("CLICK", "DOUBLE", "HOLD").
    @Published var buttonActions: [String: String] { didSet { d.set(buttonActions, forKey: "buttonActions") } }
    @Published var keepListening: Bool { didSet { d.set(keepListening, forKey: "keepListening") } }
    /// Which mic a ring-gesture voice turn uses: "auto" (AirPods while the app is open,
    /// the ring in the background), "airpods" or "ring".
    @Published var talkMic: String { didSet { d.set(talkMic, forKey: "talkMic") } }
    /// The ring gesture only starts a voice turn while headphones (e.g. AirPods) are connected.
    @Published var requireHeadphones: Bool { didSet { d.set(requireHeadphones, forKey: "requireHeadphones") } }
    @Published var voiceId: String { didSet { d.set(voiceId, forKey: "voiceId") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    /// Who reads replies aloud: "openai" (natural, needs a key) or "apple" (on-device).
    @Published var voiceEngine: String { didSet { d.set(voiceEngine, forKey: "voiceEngine") } }
    @Published var openAIKey: String { didSet { Keychain.set("openaiKey", openAIKey) } }
    @Published var ttsVoice: String { didSet { d.set(ttsVoice, forKey: "ttsVoice") } }
    /// How the OpenAI voice should sound (tone, pace, accent).
    @Published var ttsStyle: String { didSet { d.set(ttsStyle, forKey: "ttsStyle") } }

    init() {
        apiKey = Keychain.get("claudeKey")
        houseToken = Keychain.get("houseToken")
        houseName = d.string(forKey: "houseName") ?? HouseAgentDefaults.name
        houseURL = d.string(forKey: "houseURL") ?? HouseAgentDefaults.url
        userName = d.string(forKey: "userName") ?? ""
        autoAnalyze = d.object(forKey: "autoAnalyze") as? Bool ?? true
        autoDownload = d.object(forKey: "autoDownload") as? Bool ?? true
        if let saved = d.dictionary(forKey: "buttonActions") as? [String: String] {
            buttonActions = saved
        } else {
            // First run of this version: carry over the old "gesture to talk" choice.
            var a = ["CLICK": ButtonAction.none.rawValue, "DOUBLE": ButtonAction.none.rawValue,
                     "HOLD": ButtonAction.talk.rawValue]
            if d.string(forKey: "voiceGesture") == "DOUBLE" {
                a["DOUBLE"] = ButtonAction.talk.rawValue
                a["HOLD"] = ButtonAction.none.rawValue
            }
            buttonActions = a
        }
        keepListening = d.object(forKey: "keepListening") as? Bool ?? true
        talkMic = d.string(forKey: "talkMic") ?? "auto"
        requireHeadphones = d.object(forKey: "requireHeadphones") as? Bool ?? true
        voiceId = d.string(forKey: "voiceId") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        openAIKey = Keychain.get("openaiKey")
        voiceEngine = d.string(forKey: "voiceEngine") ?? "openai"
        ttsVoice = d.string(forKey: "ttsVoice") ?? "coral"
        ttsStyle = d.string(forKey: "ttsStyle") ?? OpenAITTS.defaultStyle
    }

    var claude: Claude { Claude(apiKey: apiKey) }
    var house: HouseAgentClient { HouseAgentClient(baseURL: houseURL, token: houseToken) }
    /// What the user calls their house agent (shown in the UI and told to Claude).
    var houseLabel: String {
        let n = houseName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "the house agent" : n
    }
    var hasClaude: Bool { !apiKey.isEmpty }

    func action(for gesture: String) -> ButtonAction {
        ButtonAction(rawValue: buttonActions[gesture] ?? "") ?? .none
    }

    /// Replies use the OpenAI voice when chosen and a key is set; otherwise the Apple voice.
    var useCloudVoice: Bool { voiceEngine == "openai" && !openAIKey.isEmpty }
    var tts: OpenAITTS { OpenAITTS(apiKey: openAIKey, voice: ttsVoice, style: ttsStyle) }
}

/// What a ring input can do.
enum ButtonAction: String, CaseIterable, Identifiable {
    case none, talk, stopTalking, playPause, nextTrack
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Nothing"
        case .talk: return "Talk to the agent"
        case .stopTalking: return "Stop the agent"
        case .playPause: return "Play/Pause music"
        case .nextTrack: return "Next track"
        }
    }
    /// The ring inputs that can be mapped, with their labels.
    static let inputs: [(gesture: String, label: String)] = [
        ("CLICK", "Single click"), ("DOUBLE", "Double click"), ("HOLD", "Hold"),
    ]
}
