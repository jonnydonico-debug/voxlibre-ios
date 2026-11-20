import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var e: RingEngine
    @EnvironmentObject var notes: NotesStore
    @State private var filter = 0  // 0=all, 1=on ring, 2=local
    @State private var confirmRingDelete: Rec?

    private var items: [Rec] {
        e.library.filter {
            switch filter {
            case 1: return $0.onRing
            case 2: return $0.savedLocal
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if items.isEmpty {
                    Text(e.library.isEmpty ? "No recordings yet" : "Nothing in this filter")
                        .foregroundStyle(Color.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(items) { r in
                        NavigationLink { RecordingDetailView(rec: r) } label: { row(r) }
                    }
                        .listStyle(.plain)
                        .refreshable { e.manualRefresh() }
                }
            }
            Divider()
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(0)
                    Text("On ring").tag(1)
                    Text("Local").tag(2)
                }
                .pickerStyle(.segmented)
                Button { e.manualRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!e.connected)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.15))
        }
        .confirmationDialog("Delete this recording from the ring?",
                            isPresented: Binding(get: { confirmRingDelete != nil },
                                                 set: { if !$0 { confirmRingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmRingDelete) { r in
            Button("Delete from ring", role: .destructive) { e.deleteRing(r.id) }
        } message: { r in
            Text(r.savedLocal ? "A copy stays on this phone." : "It hasn't been downloaded — this can't be undone.")
        }
    }

    @ViewBuilder private func row(_ r: Rec) -> some View {
        let (status, color): (String, Color) =
            r.onRing && r.savedLocal ? ("Synced", .synced) : (r.onRing ? ("On ring", .lime) : ("On phone only", .muted))
        HStack(spacing: 12) {
            Image(systemName: r.savedLocal ? "checkmark.circle.fill" : "mic.fill")
                .foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.uppercased()).font(.caption2).kerning(0.5).foregroundStyle(color)
                    aiBadge(r)
                }
                if let title = notes.notes[r.id]?.analysis?.title, !title.isEmpty {
                    Text(title).font(.subheadline).lineLimit(2)
                    Text(Self.fmtTs(r.id)).font(.caption).foregroundStyle(Color.muted)
                } else {
                    Text(Self.fmtTs(r.id)).font(.subheadline)
                }
                Text((r.size >= 0 ? ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file) : "—")
                     + (r.durationMs.map { " · " + Self.fmtDur($0) } ?? ""))
                    .font(.caption).foregroundStyle(Color.muted)
            }
            Spacer()
            if r.savedLocal {
                Button {
                    e.playingId == r.id ? e.stopPlay() : e.play(r)
                } label: {
                    Image(systemName: e.playingId == r.id ? "stop.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.borderless)
            } else if e.downloadingName == r.name {
                ProgressView()
            } else {
                Button { e.download(r.name) } label: {
                    Image(systemName: "arrow.down.circle").font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!e.connected || e.downloading)
            }
            Menu {
                if r.savedLocal, let url = e.shareURL(r) {
                    ShareLink(item: url) { Label("Share / Save to Files", systemImage: "square.and.arrow.up") }
                }
                if r.onRing {
                    Button(role: .destructive) { confirmRingDelete = r } label: {
                        Label("Delete from ring", systemImage: "trash")
                    }
                    .disabled(!e.connected)
                }
                if r.savedLocal {
                    Button(role: .destructive) { e.deleteLocal(r.id) } label: {
                        Label("Delete from phone", systemImage: "iphone.slash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .foregroundStyle(Color.muted)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func aiBadge(_ r: Rec) -> some View {
        if let st = notes.stage[r.id] {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text(Self.stageLabel(st)).font(.caption2).foregroundStyle(Color.muted)
            }
        } else if let n = notes.notes[r.id] {
            if n.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Color.amber)
            } else if n.analysis != nil {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.lime)
            } else if n.segments != nil {
                Image(systemName: "text.quote").font(.caption2).foregroundStyle(Color.muted)
            }
        }
    }

    static func stageLabel(_ s: NotesStore.Stage) -> String {
        switch s {
        case .queued: return "queued"
        case .decoding: return "decoding"
        case .transcribing: return "transcribing"
        case .analyzing: return "analysing"
        }
    }

    private static let tsFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func fmtTs(_ id: String) -> String {
        guard let t = TimeInterval(id) else { return id }
        return tsFmt.string(from: Date(timeIntervalSince1970: t))
    }

    static func fmtDur(_ ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms"
    }
}
