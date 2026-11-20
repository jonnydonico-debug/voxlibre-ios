import SwiftUI

/// Chat with the ring agent by text or voice (AirPods).
struct AgentView: View {
    @EnvironmentObject var agent: ChatAgent
    @EnvironmentObject var voice: VoiceIO
    @EnvironmentObject var settings: AISettings
    @State private var draft = ""
    @State private var showMemory = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !settings.hasClaude {
                Label("Add your Claude API key in Settings › AI & voice.", systemImage: "key")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.amber.opacity(0.2))
            }
            messages
            Divider()
            bottomBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { showMemory = true } label: { Image(systemName: "brain") }
                Button { agent.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(agent.items.isEmpty)
            }
        }
        .sheet(isPresented: $showMemory) { MemoryView() }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.items.isEmpty { emptyHint }
                    ForEach(agent.items) { item in bubble(item).id(item.id) }
                    if !agent.status.isEmpty || voice.state == .listening {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(voice.state == .listening ? (voice.partial.isEmpty ? "Listening…" : voice.partial) : agent.status)
                                .foregroundStyle(Color.muted)
                        }
                        .id("status")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: agent.items.last?.text) { _, _ in withAnimation { proxy.scrollTo(agent.items.last?.id, anchor: .bottom) } }
            .onChange(of: agent.status) { _, _ in withAnimation { proxy.scrollTo("status", anchor: .bottom) } }
            .onChange(of: voice.partial) { _, _ in proxy.scrollTo("status", anchor: .bottom) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.house.isConfigured
                 ? "Ask about your recordings or things you've told it to remember, or ask \(settings.houseLabel) to do something at home."
                 : "Ask about your recordings or things you've told it to remember.")
                .foregroundStyle(Color.muted)
            ForEach(["What did I agree to do this week?", "Summarise my meeting with Sam", "Remember that my sister's birthday is 3 March"]
                    + (settings.house.isConfigured ? ["Ask \(settings.houseLabel) to turn off the living room lights"] : []), id: \.self) { s in
                Button(s) { agent.sendText(s) }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .disabled(!settings.hasClaude)
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder private func bubble(_ item: ChatItem) -> some View {
        switch item.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                HStack(alignment: .top, spacing: 4) {
                    if item.spoken { Image(systemName: "waveform").font(.caption2) }
                    Text(item.text)
                }
                .padding(10)
                .background(Color.lime.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
            }
        case "assistant":
            HStack {
                Text(LocalizedStringKey(item.text))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        default:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                    .disabled(agent.busy || !settings.hasClaude)
            } else {
                Button {
                    typing = false
                    if agent.conversationActive || voice.state == .speaking { agent.stop() } else { agent.startVoice() }
                } label: {
                    Image(systemName: agent.conversationActive ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(agent.conversationActive ? Color.danger : Color.lime)
                        .symbolEffect(.pulse, isActive: voice.state == .listening)
                }
                .disabled(!settings.hasClaude || (agent.busy && !agent.conversationActive))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func send() {
        let t = draft
        draft = ""
        agent.sendText(t)
    }
}

/// The agent's long-term memory: view, add, edit, delete.
struct MemoryView: View {
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var notes: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MemoryItem?
    @State private var adding = false
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                if memory.items.isEmpty {
                    Text("Nothing remembered yet. The agent saves important facts from your recordings and chats here, and you can add your own.")
                        .foregroundStyle(Color.muted)
                }
                ForEach(memory.items) { m in
                    Button {
                        text = m.text
                        editing = m
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.text).foregroundStyle(.primary)
                            Text(([m.about] + [source(m)]).filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Color.muted)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { memory.remove(m.id) } }
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { text = ""; adding = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("Remember", isPresented: $adding) {
                TextField("Something to remember", text: $text)
                Button("Save") { memory.add(text, source: "you") }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Edit memory", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Memory", text: $text)
                Button("Save") {
                    if var m = editing, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        m.text = text
                        memory.update(m)
                    }
                }
                Button("Delete", role: .destructive) { if let m = editing { memory.remove(m.id) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func source(_ m: MemoryItem) -> String {
        switch m.source {
        case "chat": return "from chat"
        case "you": return "added by you"
        default: return "from \"\(notes.title(m.source))\""
        }
    }
}
