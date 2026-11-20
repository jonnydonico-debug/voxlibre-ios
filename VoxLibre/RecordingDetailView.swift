import SwiftUI

/// One recording: playback, AI status, summary, speakers, insights, action items,
/// what was remembered, and the speaker-labelled transcript.
struct RecordingDetailView: View {
    let rec: Rec
    @EnvironmentObject var e: RingEngine
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var settings: AISettings
    @State private var renaming: Speaker?
    @State private var newName = ""
    @State private var sending: String?

    private var n: RecordingNotes? { notes.notes[rec.id] }
    private var a: Analysis? { n?.analysis }
    private var live: Rec { e.library.first { $0.id == rec.id } ?? rec }

    var body: some View {
        List {
            header
            if let a {
                if !a.summary.isEmpty { Section("Summary") { Text(a.summary) } }
                if !a.speakers.isEmpty { speakersSection(a) }
                if !a.insights.isEmpty { bullets("Insights", a.insights, icon: "lightbulb") }
                if !a.decisions.isEmpty { bullets("Decisions", a.decisions, icon: "checkmark.seal") }
                if !a.actionItems.isEmpty { actionsSection(a) }
                rememberedSection(a)
                if !a.topics.isEmpty {
                    Section("Topics") { Text(a.topics.map { "#" + $0 }.joined(separator: "  ")).foregroundStyle(Color.muted) }
                }
            }
            if let n, let segs = n.segments, !segs.isEmpty { transcriptSection(n) }
        }
        .navigationTitle(a?.title.isEmpty == false ? a!.title : "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let s = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    notes.renameSpeaker(rec.id, label: s.label, to: newName.trimmingCharacters(in: .whitespaces))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(renaming?.evidence ?? "")
        }
    }

    // MARK: header / status
    @ViewBuilder private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(LibraryView.fmtTs(rec.id)).font(.subheadline)
                Text([a?.kind.capitalized, live.durationMs.map(LibraryView.fmtDur)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Color.muted)
            }
            HStack(spacing: 12) {
                if live.savedLocal {
                    Button {
                        e.playingId == rec.id ? e.stopPlay() : e.play(live)
                    } label: {
                        Label(e.playingId == rec.id ? "Stop" : "Play", systemImage: e.playingId == rec.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                } else if e.downloadingName == rec.name {
                    ProgressView()
                    Text("Downloading…").foregroundStyle(Color.muted)
                } else {
                    Button { e.download(rec.name) } label: { Label("Download from ring", systemImage: "arrow.down.circle") }
                        .buttonStyle(.bordered)
                        .disabled(!e.connected || e.downloading)
                }
                Spacer()
                aiButton
            }
            if let st = notes.stage[rec.id] {
                HStack {
                    ProgressView()
                    Text(LibraryView.stageLabel(st).capitalized + "…").foregroundStyle(Color.muted)
                }
            }
            if let err = n?.error {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(Color.amber).font(.footnote)
            }
            if n?.segments != nil && a == nil && !settings.hasClaude {
                Text("Add a Claude API key in Settings › AI & voice to get a summary, speakers and action items.")
                    .font(.footnote).foregroundStyle(Color.muted)
            }
        }
    }

    @ViewBuilder private var aiButton: some View {
        if live.savedLocal && notes.stage[rec.id] == nil {
            if n?.segments == nil || (a == nil && settings.hasClaude) {
                Button { notes.process(rec.id) } label: {
                    Label(n?.segments == nil ? "Transcribe" : "Analyse", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
            } else if a != nil {
                Menu {
                    Button { notes.process(rec.id, force: true) } label: { Label("Analyse again", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    // MARK: sections
    private func speakersSection(_ a: Analysis) -> some View {
        Section {
            ForEach(a.speakers, id: \.label) { s in
                Button {
                    newName = s.name
                    renaming = s
                } label: {
                    HStack {
                        Circle().fill(Self.color(s.label)).frame(width: 10, height: 10)
                        Text(s.name).foregroundStyle(.primary)
                        if s.isWearer { Text("you").font(.caption).foregroundStyle(Color.lime) }
                        Spacer()
                        Image(systemName: "pencil").font(.caption).foregroundStyle(Color.muted)
                    }
                }
            }
        } header: { Text("Speakers") } footer: { Text("Guessed from the conversation. Tap to correct a name.") }
    }

    private func bullets(_ title: String, _ items: [String], icon: String) -> some View {
        Section(title) {
            ForEach(items, id: \.self) { t in
                Label(t, systemImage: icon).labelStyle(BulletLabel())
            }
        }
    }

    private func actionsSection(_ a: Analysis) -> some View {
        Section {
            ForEach(a.actionItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Button {
                            var i = item
                            i.done.toggle()
                            notes.updateActionItem(rec.id, i)
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? Color.lime : Color.muted)
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).strikethrough(item.done)
                            let meta = [item.owner, item.due.isEmpty ? "" : "due \(item.due)"].filter { !$0.isEmpty }
                            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(Color.muted) }
                        }
                        Spacer()
                        if settings.house.isConfigured && item.houseReply == nil {
                            if sending == item.id {
                                ProgressView()
                            } else {
                                Button { sendToHouse(item, a) } label: { Label("Send", systemImage: "house") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(sending != nil)
                            }
                        }
                    }
                    if let reply = item.houseReply {
                        Label(reply, systemImage: "house").font(.caption).foregroundStyle(Color.muted)
                    }
                }
            }
        } header: { Text("Action items") } footer: {
            if settings.house.isConfigured { Text("\"Send\" asks \(settings.houseLabel) to add it to your to-dos.") }
        }
    }

    @ViewBuilder private func rememberedSection(_ a: Analysis) -> some View {
        let mems = memory.items.filter { $0.source == rec.id }
        if !mems.isEmpty {
            Section {
                ForEach(mems) { m in
                    Text(m.text)
                        .swipeActions { Button("Forget", role: .destructive) { memory.remove(m.id) } }
                }
            } header: { Text("Remembered") } footer: { Text("Saved to the agent's memory. Swipe to forget.") }
        }
    }

    private func transcriptSection(_ n: RecordingNotes) -> some View {
        Section("Transcript") {
            ForEach(Array(Self.turns(n).enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let l = t.label {
                            Text(n.speakerName(l)).font(.caption.bold()).foregroundStyle(Self.color(l))
                        }
                        Text(fmtTime(t.start)).font(.caption).foregroundStyle(Color.muted)
                    }
                    Text(t.text).textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: helpers
    private func sendToHouse(_ item: ActionItem, _ a: Analysis) {
        sending = item.id
        var msg = "Please add this to my to-do list: \(item.text)"
        if !item.due.isEmpty { msg += " (due \(item.due))" }
        if !item.owner.isEmpty && item.owner != settings.userName { msg += " — it's for \(item.owner)" }
        msg += ". It came from my recording \"\(a.title)\"."
        Task { @MainActor in
            var i = item
            do { i.houseReply = try await settings.house.ask(msg) }
            catch { e.toast(error.localizedDescription) }
            if i.houseReply != nil { notes.updateActionItem(rec.id, i) }
            sending = nil
        }
    }

    struct Turn { let label: String?; let start: Double; let text: String }

    static func turns(_ n: RecordingNotes) -> [Turn] {
        var out: [Turn] = []
        for s in n.segments ?? [] {
            if let last = out.last, last.label == s.speaker {
                out[out.count - 1] = Turn(label: last.label, start: last.start, text: last.text + " " + s.text)
            } else {
                out.append(Turn(label: s.speaker, start: s.start, text: s.text))
            }
        }
        return out
    }

    static func color(_ label: String) -> Color {
        let palette: [Color] = [.lime, .synced, .amber, .pink, .purple, .teal, .orange]
        let n = Int(label.filter(\.isNumber)) ?? 0
        return palette[(max(n, 1) - 1) % palette.count]
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(Color.muted).font(.caption)
            configuration.title
        }
    }
}
