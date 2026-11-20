import SwiftUI

struct LogsView: View {
    @EnvironmentObject var e: RingEngine
    @State private var onlyUnmapped = false
    @State private var wordWrap = false

    private var shown: [LogLine] { e.logs.filter { !onlyUnmapped || $0.unmapped } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(wordWrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { l in
                            Text(l.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(l.unmapped ? Color.lime : Color(white: 0.7))
                                .lineLimit(wordWrap ? nil : 1)
                                .fixedSize(horizontal: !wordWrap, vertical: false)
                                .textSelection(.enabled)
                                .id(l.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: shown.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            VStack(spacing: 0) {
                Toggle("Unmapped interactions only", isOn: $onlyUnmapped)
                Toggle("Word wrap", isOn: $wordWrap)
                HStack {
                    ShareLink(item: e.logs.map(\.text).joined(separator: "\n")) {
                        Label("Share logs", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button("Clear", role: .destructive) { e.clearLogs() }
                }
                .padding(.top, 6)
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(white: 0.15))
        }
    }
}
