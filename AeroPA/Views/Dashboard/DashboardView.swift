import SwiftUI
import AeroPACore

struct DashboardView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @State private var showConnection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                DashboardHeader(showConnection: $showConnection)
                if !app.connectionState.isReceiving && !app.provider.isSimulated {
                    NoSimulatorCard { showConnection = true }
                }
                PhaseCard()
                FlightDataGrid()
                NowPlayingCard()
                ForEach(app.warnings, id: \.self) { WarningRow(text: $0) }
                CompanionButton()
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .screenBackground()
        .navigationTitle("AeroPA")
        .largeTitle()
        .sheet(isPresented: $showConnection) {
            NavigationStack { ConnectionView() }
        }
    }
}

private struct DashboardHeader: View {
    @EnvironmentObject var app: CompanionCoordinator
    @Binding var showConnection: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.currentPack?.manifest.name ?? "No airline")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(app.currentProfile?.name ?? "No aircraft")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { showConnection = true } label: { ConnectionPill() }
                .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}

struct ConnectionPill: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: app.connectionState.color, pulsing: app.connectionState.isReceiving)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.connectionState.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            if app.provider.isSimulated {
                Text("DEMO")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.caution.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.caution)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private var subtitle: String {
        if app.provider.isSimulated { return "Demo flight" }
        if app.connectionState.isReceiving { return app.diagnostics.simulatorName ?? "Simulator" }
        return "Aerofly FS"
    }
}

private struct NoSimulatorCard: View {
    let action: () -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Waiting for Aerofly", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                Text("Open Aerofly FS and turn on Broadcast flight info to IP address in its Miscellaneous settings. Use this device's IP address and port 49002.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                Button("Connection help", action: action)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }
}

private struct PhaseCard: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: app.isActive ? "Flight phase" : "Companion idle")
                Text(app.phase.displayName)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: app.phase)
                PhaseProgressView(phase: app.phase)
                if app.settings.phaseDetection == .manual {
                    Label("Manual phase control", systemImage: "hand.tap")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.caution)
                }
            }
        }
    }
}

struct PhaseProgressView: View {
    let phase: FlightPhase
    private let all = FlightPhase.allCases

    var body: some View {
        HStack(spacing: 3) {
            ForEach(all, id: \.self) { p in
                Capsule()
                    .fill(p <= phase ? Theme.accent : Theme.surfaceRaised)
                    .opacity(p == phase ? 1 : (p < phase ? 0.55 : 1))
                    .frame(height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: phase)
        .accessibilityLabel("Phase \(phase.order + 1) of \(all.count)")
    }
}

private struct FlightDataGrid: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        let s = app.aircraft
        let speed = s?.airspeed(allowGroundSpeedEstimate: true)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricTile(label: "Altitude", value: Format.feet(s?.altitudeMSLFeet), unit: "ft")
            MetricTile(label: speed?.estimated == true ? "Ground speed" : "Airspeed",
                       value: Format.knots(speed?.knots), unit: "kt",
                       note: speed?.estimated == true ? "IAS not broadcast" : nil)
            MetricTile(label: "Vertical speed", value: Format.fpm(s?.verticalSpeedFPM), unit: "fpm",
                       note: s?.verticalSpeedIsDerived == true ? "Derived" : nil)
            MetricTile(label: "Heading", value: Format.heading(s?.headingDegrees ?? s?.trackDegrees), unit: "",
                       note: s?.headingDegrees == nil && s?.trackDegrees != nil ? "Track" : nil)
        }
        .opacity(app.connectionState.isReceiving ? 1 : 0.45)
        .animation(.easeInOut, value: app.connectionState.isReceiving)
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    let unit: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: label)
                Spacer(minLength: 0)
                if let note {
                    Text(note).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.mono(28, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct NowPlayingCard: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Now playing")
                if let pa = app.nowPlaying[.pa] {
                    row(icon: "speaker.wave.2.fill", title: pa.title, subtitle: source(pa))
                }
                if let cp = app.nowPlaying[.copilot] {
                    row(icon: "headphones", title: cp.title, subtitle: "First officer")
                }
                if app.nowPlaying[.pa] == nil && app.nowPlaying[.copilot] == nil {
                    Text(app.lastAnnouncementText ?? "Nothing yet. Announcements play automatically as the flight progresses.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    Image(systemName: app.nowPlaying[.ambience] != nil ? "wind" : "wind.slash")
                    Text(app.nowPlaying[.ambience] != nil ? "Cabin ambience on" : "Ambience off")
                    if !app.audioRoute.isEmpty { Text("· \(app.audioRoute)") }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func source(_ r: AudioRequest) -> String {
        if case .speech = r.source { return "Synthesized voice" }
        return "Recorded announcement"
    }
}

struct WarningRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CompanionButton: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                app.isActive ? app.stopCompanion() : app.startCompanion()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: app.isActive ? "stop.fill" : "play.fill")
                Text(app.isActive ? "Stop Companion" : "Start Companion")
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .foregroundStyle(app.isActive ? Theme.textPrimary : Color.black)
            .background(app.isActive ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.textPrimary),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .hapticFeedback(trigger: app.isActive)
        .accessibilityHint("Starts automatic announcements and callouts")
    }
}
