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
                Picker("Reads replies", selection: $s.voiceEngine) {
                    Text("Natural (OpenAI)").tag("openai")
                    Text("On-device (Apple)").tag("apple")
                }
                if s.voiceEngine == "openai" {
                    SecureField("OpenAI API key (sk-…)", text: $s.openAIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Voice", selection: $s.ttsVoice) {
                        ForEach(OpenAITTS.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How it should sound").font(.caption).foregroundStyle(Color.muted)
                        TextField("e.g. warm, relaxed, a little slower", text: $s.ttsStyle, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    if s.ttsStyle != OpenAITTS.defaultStyle {
                        Button("Reset to the default style") { s.ttsStyle = OpenAITTS.defaultStyle }
                    }
                }
                Picker(s.voiceEngine == "openai" ? "Offline voice" : "Voice", selection: $s.voiceId) {
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
                Button("Play a sample") { Task { await voice.say("Hey! This is how I'll sound in your AirPods. Hold the ring whenever you want to talk.") } }
            } header: { Text("Voice") } footer: {
                Text(s.voiceEngine == "openai"
                     ? "Replies are read by OpenAI's \(OpenAITTS.model) with your own key (stored in the Keychain). Only the reply text is sent to OpenAI. Without a key, or when OpenAI can't be reached, the offline Apple voice reads instead; the speed slider applies to it only."
                     : "For better Apple voices, download an Enhanced or Premium voice in iOS Settings › Accessibility › Spoken Content › Voices.")
            }

            Section {
                Toggle("Keep listening after replies", isOn: $s.keepListening)
                Picker("Talk into", selection: $s.talkMic) {
                    Text("Auto").tag("auto")
                    Text("AirPods mic").tag("airpods")
                    Text("Ring mic").tag("ring")
                }
                Toggle("Only with headphones in", isOn: $s.requireHeadphones)
            } header: { Text("Talking") } footer: {
                Text("Choose which ring input talks to the agent on the Ring tab.\n\nAirPods mic: a back-and-forth conversation, only while VoxLibre is open. Ring mic: push-to-talk. Hold the ring while you speak; when you let go, the clip downloads, is transcribed and answered, also with the phone locked. Auto uses the AirPods mic while the app is open and the ring mic otherwise.")
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
