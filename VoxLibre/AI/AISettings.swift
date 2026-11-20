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
    /// Ring gesture that starts a voice chat: "off", "DOUBLE" or "HOLD".
    @Published var voiceGesture: String { didSet { d.set(voiceGesture, forKey: "voiceGesture") } }
    @Published var keepListening: Bool { didSet { d.set(keepListening, forKey: "keepListening") } }
    @Published var voiceId: String { didSet { d.set(voiceId, forKey: "voiceId") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }

    init() {
        apiKey = Keychain.get("claudeKey")
        houseToken = Keychain.get("houseToken")
        houseName = d.string(forKey: "houseName") ?? HouseAgentDefaults.name
        houseURL = d.string(forKey: "houseURL") ?? HouseAgentDefaults.url
        userName = d.string(forKey: "userName") ?? ""
        autoAnalyze = d.object(forKey: "autoAnalyze") as? Bool ?? true
        autoDownload = d.object(forKey: "autoDownload") as? Bool ?? true
        voiceGesture = d.string(forKey: "voiceGesture") ?? "off"
        keepListening = d.object(forKey: "keepListening") as? Bool ?? true
        voiceId = d.string(forKey: "voiceId") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate)
    }

    var claude: Claude { Claude(apiKey: apiKey) }
    var house: HouseAgentClient { HouseAgentClient(baseURL: houseURL, token: houseToken) }
    /// What the user calls their house agent (shown in the UI and told to Claude).
    var houseLabel: String {
        let n = houseName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "the house agent" : n
    }
    var hasClaude: Bool { !apiKey.isEmpty }
}
