import SwiftUI

struct RingView: View {
    @EnvironmentObject var e: RingEngine
    @State private var picker = false

    var body: some View {
        Group {
            if e.connected { connectedBody } else { emptyState }
        }
        .sheet(isPresented: $picker) {
            RingPickerView { r in
                e.selectRing(r)
                if e.hasCredentials { e.toggleConnect() }
            }
        }
    }

    // MARK: disconnected
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48)).foregroundStyle(Color.muted)
            if e.isConfigured {
                Text(e.active ? "Connecting…" : "Ring disconnected").font(.title3)
                Text(e.hasCredentials ? "Tap Connect to see the ring data"
                                      : "Enter BIND KEY and USER ID in Settings (gear icon)")
                    .font(.footnote).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                Text(e.ringName).font(.caption).foregroundStyle(Color.muted)
                if e.active { ProgressView().padding(.top, 6) }
            } else {
                Text("No ring selected").font(.title3)
                Text("Find your Vocci ring nearby")
                    .font(.footnote).foregroundStyle(Color.muted)
                Button("Select ring") { picker = true }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: connected
    private var connectedBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.model.isEmpty ? "Ring" : e.model)
                        .font(.system(size: 26, weight: .medium))
                        .padding(.bottom, 10)
                    if !e.sn.isEmpty { kv("SN", e.sn) }
                    if !e.fw.isEmpty { kv("Firmware", e.fw) }
                    if !e.hw.isEmpty { kv("Hardware", e.hw) }

                    if e.battPct >= 0 || e.storTot > 0 || e.rssiHost > 0 {
                        Divider().padding(.vertical, 14)
                        chips
                        HStack(alignment: .top, spacing: 16) {
                            Metric(icon: "battery.100", label: "Battery",
                                   value: e.battPct >= 0 ? "\(e.battPct)" : "—", unit: "%",
                                   color: e.battPct < 0 ? .primary : battColor,
                                   progress: e.battPct >= 0 ? Double(e.battPct) / 100 : nil)
                            Metric(icon: "internaldrive", label: "Free",
                                   value: e.storTot > 0 ? String(format: "%.1f", Double(e.storFree) / 1_048_576) : "—",
                                   unit: "MB", color: .primary,
                                   progress: e.storTot > 0 ? Double(e.storFree) / Double(e.storTot) : nil)
                        }
                    }

                    if !e.eventText.isEmpty || !e.gestureText.isEmpty { Divider().padding(.vertical, 14) }
                    if !e.eventText.isEmpty { labeled("Event", e.eventText) }
                    if !e.gestureText.isEmpty { labeled("Gesture", e.gestureText) }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Toggle(isOn: $e.mediaToggle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Single click → Play/Pause")
                    Text("Controls the Music app").font(.caption2).foregroundStyle(Color.muted)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color(white: 0.15))
        }
    }

    private var battColor: Color { e.battPct <= 15 ? .danger : (e.battPct <= 35 ? .amber : .lime) }

    @ViewBuilder private var chips: some View {
        let items: [(String, String)] = {
            var a: [(String, String)] = []
            if e.battSt != 0 { a.append(("Charging", "bolt.fill")) }
            if e.rssiHost > 0 {
                let q = e.rssiHost <= 60 ? "Strong signal" : (e.rssiHost <= 75 ? "Medium signal" : "Weak signal")
                a.append(("-\(e.rssiHost) dBm · \(q)", "cellularbars"))
            }
            if e.battVolt > 0 { a.append((String(format: "%.2f V", Double(e.battVolt) / 1000), "bolt")) }
            return a
        }()
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.0) { t, ic in
                        Label(t, systemImage: ic)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(Capsule().stroke(Color.muted.opacity(0.5)))
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Color.muted)
            Spacer()
            Text(v).textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }

    private func labeled(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l.uppercased()).font(.caption2).kerning(1).foregroundStyle(Color.muted)
            Text(v)
        }
        .padding(.vertical, 6)
    }
}

private struct Metric: View {
    let icon: String, label: String, value: String, unit: String
    let color: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label.uppercased(), systemImage: icon)
                .font(.caption2).foregroundStyle(Color.muted)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .bold)).foregroundStyle(color)
                Text(unit).font(.caption).foregroundStyle(Color.muted)
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
