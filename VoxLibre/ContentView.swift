import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var e: RingEngine
    @State private var tab = 0
    @State private var showSettings = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { RingView().chrome($showSettings) }
                .tabItem { Label("Ring", systemImage: "dot.radiowaves.left.and.right") }
                .tag(0)
            NavigationStack { LibraryView().chrome($showSettings) }
                .tabItem { Label("Recordings", systemImage: "mic.fill") }
                .tag(1)
            NavigationStack { AgentView().chrome($showSettings) }
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag(2)
            NavigationStack { LogsView().chrome($showSettings) }
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
                .tag(3)
        }
        .onChange(of: tab) { _, t in if t == 1 { e.refreshLibrary() } }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .overlay(alignment: .bottom) {
            if let t = e.toastText {
                Text(t)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: e.toastText)
    }
}

/// Shared top bar: title + connection status, Connect button, settings gear.
private struct Chrome: ViewModifier {
    @EnvironmentObject var e: RingEngine
    @Binding var showSettings: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("VoxLibre").font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(dotColor).frame(width: 7, height: 7)
                            Text(e.status).font(.caption2).foregroundStyle(Color.muted)
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if e.isConfigured {
                        Button(e.active ? "Disconnect" : "Connect") { e.toggleConnect() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
    }

    private var dotColor: Color {
        e.connected ? .lime : (e.active ? .amber : .gray)
    }
}

extension View {
    func chrome(_ showSettings: Binding<Bool>) -> some View { modifier(Chrome(showSettings: showSettings)) }
}

// MARK: - Ring picker

struct RingPickerView: View {
    @EnvironmentObject var e: RingEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false
    var onPick: (DiscoveredRing) -> Void

    private var shown: [DiscoveredRing] {
        e.discovered
            .filter { showAll || $0.name != nil || $0.systemConnected }
            .sorted { ($0.systemConnected ? 1 : 0, $0.rssi) > ($1.systemConnected ? 1 : 0, $1.rssi) }
    }

    var body: some View {
        NavigationStack {
            List {
                if e.btState != .poweredOn {
                    Label(btMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.amber)
                }
                Section {
                    ForEach(shown) { r in
                        Button {
                            onPick(r)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.name ?? "(no name)").foregroundStyle(.primary)
                                    Text(r.id.uuidString).font(.caption2).foregroundStyle(Color.muted)
                                }
                                Spacer()
                                if r.systemConnected {
                                    Text("connected").font(.caption).foregroundStyle(Color.lime)
                                } else {
                                    Text("\(r.rssi) dBm").font(.caption).foregroundStyle(Color.muted)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby devices")
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                } footer: {
                    Text("Wake the ring and keep it close. If it's connected to the official app on another phone, disconnect it there first.")
                }
                Toggle("Show unnamed devices", isOn: $showAll)
            }
            .navigationTitle("Select ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { e.startPickerScan() }
            .onDisappear { e.stopPickerScan() }
        }
    }

    private var btMessage: String {
        switch e.btState {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied — enable it in Settings › VoxLibre"
        case .unsupported: return "Bluetooth LE not supported here (simulator?)"
        default: return "Waiting for Bluetooth…"
        }
    }
}
