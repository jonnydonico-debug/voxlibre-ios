import SwiftUI
import AVFoundation

/// Settings for transcription, the Claude agent, voice and the house agent. Changes save immediately.
struct AISettingsView: View {
    @EnvironmentObject var s: AISettings
    @EnvironmentObject var voice: VoiceIO
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                SecureField("Claude API key (sk-ant-…)", text: $s.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Your name", text: $s.userName)
            } header: { Text("Claude") } footer: {
                Text("Model: \(Claude.model). Your key is stored in this iPhone's Keychain. Transcripts and chats are sent to Anthropic's API for analysis; the audio itself stays on the phone.")
            }

            Section {
                Toggle("Download new recordings", isOn: $s.autoDownload)
                Toggle("Transcribe and analyse them", isOn: $s.autoAnalyze)
            } header: { Text("Recordings") } footer: {
                Text("Transcription runs on the iPhone (Apple's on-device speech recognition). Analysis — summary, speakers, insights, action items and memories — uses Claude.")
            }

            Section {
                Picker("Voice", selection: $s.voiceId) {
                    Text("Automatic").tag("")
                    ForEach(VoiceIO.voices, id: \.identifier) { v in
                        Text("\(v.name) (\(Self.quality(v)))").tag(v.identifier)
                    }
                }
                HStack {
                    Image(systemName: "tortoise").foregroundStyle(Color.muted)
                    Slider(value: $s.speechRate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate) * 0.75)
                    Image(systemName: "hare").foregroundStyle(Color.muted)
                }
                Button("Play a sample") { Task { await voice.say("Hi! This is how I'll sound in your AirPods.") } }
                Toggle("Keep listening after replies", isOn: $s.keepListening)
                Picker("Ring gesture to talk", selection: $s.voiceGesture) {
                    Text("Off").tag("off")
                    Text("Double click").tag("DOUBLE")
                    Text("Hold").tag("HOLD")
                }
            } header: { Text("Voice") } footer: {
                Text("For better voices, download an Enhanced or Premium voice in iOS Settings › Accessibility › Spoken Content › Voices. The ring gesture works while VoxLibre is open.")
            }

            Section {
                TextField("Name (e.g. Jarvis)", text: $s.houseName)
                TextField("Address (https://…)", text: $s.houseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Access token", text: $s.houseToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    testing = true
                    testResult = nil
                    Task { @MainActor in
                        do { testResult = "✅ " + (try await s.house.ask("Connection test from the VoxLibre app: just reply hi, nothing else.")) }
                        catch { testResult = "⚠️ " + error.localizedDescription }
                        testing = false
                    }
                } label: {
                    HStack {
                        Text("Test connection")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(!s.house.isConfigured || testing)
                if let testResult { Text(testResult).font(.footnote) }
            } header: { Text("House agent (optional)") } footer: {
                Text("Lets the agent hand jobs to your own smart-home assistant. It needs a small HTTPS endpoint; see the README.")
            }
        }
        .navigationTitle("AI & voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}
