import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var e: RingEngine
    @Environment(\.dismiss) private var dismiss
    @State private var bindKey = ""
    @State private var userId = ""
    @State private var mac = ""
    @State private var picker = false
    @State private var picked: DiscoveredRing?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(picked?.name ?? (e.ringName.isEmpty ? "No ring selected" : e.ringName))
                            if let id = picked?.id ?? e.ringId {
                                Text(id.uuidString).font(.caption2).foregroundStyle(Color.muted)
                            }
                        }
                        Spacer()
                        Button("Choose") { picker = true }
                    }
                    if e.isConfigured {
                        Button("Forget this ring", role: .destructive) {
                            e.forgetRing()
                            picked = nil
                        }
                    }
                } header: { Text("Ring") }

                Section {
                    field("BIND KEY", $bindKey)
                    field("USER ID (user_…)", $userId)
                } header: { Text("Credentials") } footer: {
                    Text("Minted by Vocci's servers when the ring was paired with the official app. Stored only in this iPhone's Keychain.")
                }

                Section {
                    field("Ring MAC (optional)", $mac)
                    if !e.verifiedMac.isEmpty {
                        LabeledContent("Verified MAC", value: e.verifiedMac).font(.footnote)
                    }
                } header: { Text("Advanced") } footer: {
                    Text("iOS hides Bluetooth MAC addresses. VoxLibre reads it from the ring and checks it against the ring's signature, so leave this empty unless auth fails. Format: AA:BB:CC:DD:EE:FF.")
                }

                Section {
                    NavigationLink { AISettingsView() } label: {
                        Label("AI & voice", systemImage: "sparkles")
                    }
                }

                Section {
                    LabeledContent("Recordings folder", value: "Files › On My iPhone › VoxLibre")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let picked { e.selectRing(picked) }
                        e.bindKey = bindKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        e.userId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
                        e.macOverride = mac.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $picker) { RingPickerView { picked = $0 } }
            .onAppear {
                bindKey = e.bindKey
                userId = e.userId
                mac = e.macOverride
            }
        }
    }

    private func field(_ label: String, _ v: Binding<String>) -> some View {
        TextField(label, text: v)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
