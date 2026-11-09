import SwiftUI
import AeroPACore

struct ConnectionView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    @State private var addresses: [NetworkInfo.Address] = []

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    StatusDot(color: app.connectionState.color, pulsing: app.connectionState.isReceiving)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.connectionState.title).font(.system(size: 17, weight: .semibold))
                        Text(stateDetail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                Button { app.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            }

            if case .failed(.localNetworkDenied) = app.connectionState {
                Section("Local network access") {
                    Text("AeroPA can't receive Aerofly's data until local network access is allowed. Open Settings › Privacy & Security › Local Network and turn on AeroPA.")
                        .font(.system(size: 14))
                    #if os(iOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    #endif
                }
            }

            Section {
                ForEach(addresses, id: \.self) { a in
                    LabeledContent(a.interfaceLabel) {
                        Text(a.ip).font(Theme.mono(15)).textSelection(.enabled)
                    }
                }
                if addresses.isEmpty {
                    Text("No Wi-Fi address. Connect this device to the same Wi-Fi network as the simulator.")
                        .foregroundStyle(Theme.textSecondary)
                }
                LabeledContent("UDP port") { Text("\(app.settings.udpPort)").font(Theme.mono(15)) }
            } header: {
                Text("This device")
            } footer: {
                Text("In Aerofly FS open Miscellaneous settings, turn on “Broadcast flight info to IP address”, enter the address above as the broadcast IP, and keep port \(AeroflyUDPProvider.defaultPort). If Aerofly runs on this same device, try 127.0.0.1 first, then the Wi-Fi address.")
            }

            Section("Live diagnostics") {
                LabeledContent("Simulator", value: app.diagnostics.simulatorName ?? "—")
                if app.diagnostics.simulatorName != nil && !app.diagnostics.looksLikeAerofly && !app.provider.isSimulated {
                    Text("This sender doesn't identify as Aerofly. Data is still accepted if it's valid.")
                        .font(.system(size: 12)).foregroundStyle(Theme.caution)
                }
                LabeledContent("Sender", value: app.diagnostics.lastSenderAddress ?? "—")
                LabeledContent("Packet rate", value: String(format: "%.1f Hz", app.diagnostics.packetsPerSecond))
                LabeledContent("Last packet", value: lastPacketAge)
                LabeledContent("Accepted", value: "\(app.diagnostics.acceptedCount)")
                LabeledContent("Rejected", value: "\(app.diagnostics.rejectedCount)")
                ForEach(app.diagnostics.countsByType.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    LabeledContent("  \(k)", value: "\(v)")
                }
                if let rej = app.diagnostics.lastRejection {
                    LabeledContent("Last rejection") { Text(rej).font(.system(size: 12)).foregroundStyle(Theme.caution) }
                }
                if let raw = app.diagnostics.lastPacketText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last datagram").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Text(raw).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }

            Section("Available telemetry") {
                ForEach(TelemetryCapability.allCases, id: \.self) { c in
                    HStack {
                        Text(c.displayName)
                        Spacer()
                        Image(systemName: app.capabilities.contains(c) ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(app.capabilities.contains(c) ? Theme.positive : Theme.textTertiary)
                    }
                }
            }

            Section {
                Picker("Source", selection: app.binding(\.source)) {
                    Text("Aerofly FS (UDP)").tag(TelemetrySourceKind.aerofly)
                    Text("Demo flight").tag(TelemetrySourceKind.demo)
                }
                HStack {
                    Text("Port")
                    TextField("49002", text: $portText)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort).disabled(UInt16(portText) == nil)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Demo flight is a simulated flight for testing. It's always labelled DEMO and is never shown as an Aerofly connection.")
            }
        }
        .navigationTitle("Connection")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear {
            portText = "\(app.settings.udpPort)"
            addresses = NetworkInfo.localIPv4Addresses()
        }
    }

    private func applyPort() {
        guard let p = UInt16(portText), p > 1023 else { return }
        app.updateSettings { $0.udpPort = p }
    }

    private var stateDetail: String {
        switch app.connectionState {
        case .listening(let port): return "Listening on UDP \(port). No data yet."
        case .receiving: return "Receiving telemetry"
        case .stale(let s): return "No packets for \(Int(s)) s. Is Aerofly paused?"
        case .lost: return "No data for a while. Still listening, and will resume automatically."
        case .failed(let e): return e.description
        case .disconnected: return "Not listening"
        }
    }

    private var lastPacketAge: String {
        guard let d = app.diagnostics.lastPacketWallClock else { return "—" }
        let s = Date().timeIntervalSince(d)
        return s < 1 ? "Just now" : "\(Int(s)) s ago"
    }
}
