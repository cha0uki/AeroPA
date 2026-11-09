import SwiftUI
import AeroPACore

struct SettingsView: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        List {
            Section {
                NavigationLink { FlightSetupView() } label: {
                    SettingsRow(icon: "airplane.departure", title: "Flight setup",
                                value: [app.currentProfile?.name, app.settings.flight.flightNumber.isEmpty ? nil : app.settings.flight.flightNumber]
                                    .compactMap { $0 }.joined(separator: " · "))
                }
                NavigationLink { AnnouncementPreferencesView() } label: {
                    SettingsRow(icon: "speaker.wave.2", title: "Announcements", value: app.settings.announcementsEnabled ? "On" : "Off")
                }
                NavigationLink { CopilotSettingsView() } label: {
                    SettingsRow(icon: "headphones", title: "First officer", value: app.settings.copilot.enabled ? "On" : "Off")
                }
                NavigationLink { AudioSettingsView() } label: {
                    SettingsRow(icon: "slider.vertical.3", title: "Audio", value: nil)
                }
            }
            Section {
                NavigationLink { ConnectionView() } label: {
                    SettingsRow(icon: "antenna.radiowaves.left.and.right", title: "Connection", value: app.connectionState.title)
                }
                NavigationLink { DemoControlView() } label: {
                    SettingsRow(icon: "testtube.2", title: "Demo & testing", value: app.provider.isSimulated ? "Active" : nil)
                }
            }
            Section {
                NavigationLink { FlightHistoryView() } label: { SettingsRow(icon: "clock.arrow.circlepath", title: "Flight history", value: nil) }
                NavigationLink { LimitationsView() } label: { SettingsRow(icon: "info.circle", title: "How AeroPA works", value: nil) }
            }
        }
        .navigationTitle("Settings")
        .largeTitle()
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            Text(title)
            Spacer()
            if let value, !value.isEmpty {
                Text(value).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

struct FlightHistoryView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @State private var flights: [FlightRecordSummary] = []

    var body: some View {
        List {
            if flights.isEmpty {
                Text("Completed companion sessions appear here.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(flights) { f in
                NavigationLink {
                    List(f.entries) { TimelineRow(entry: $0) }
                        .navigationTitle(f.startedAt.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(f.airline) · \(f.aircraft)").font(.system(size: 15, weight: .semibold))
                        Text("\(f.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(f.source) · \(f.entries.count) events")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .navigationTitle("Flight history")
        .inlineTitle()
        .onAppear { flights = app.recentFlights() }
    }
}

struct LimitationsView: View {
    var body: some View {
        List {
            Section("Telemetry") {
                Text("Aerofly sends position, altitude, ground speed, track, heading, pitch and bank (ForeFlight XGPS/XATT format). It doesn't send airspeed, gear, flaps, engine state or the on-ground flag.")
                Text("AeroPA derives vertical speed, infers ground and air phases from motion, and uses ground speed as an airspeed estimate (labelled “est.”). Callouts that need missing data are turned off, never faked.")
                Text("For 1,000 / 500 / minimums callouts, enter the destination field elevation in Flight setup.")
            }
            Section("Running alongside Aerofly") {
                Text("iOS suspends background apps. AeroPA keeps running while it's playing audio. With cabin ambience on, it continues to receive telemetry when you switch to Aerofly or lock the screen.")
                Text("With ambience off, keep AeroPA in the foreground (e.g. iPad Split View or Slide Over) or it may stop receiving data.")
                Text("A phone call or Siri interrupts AeroPA's audio. It resumes automatically when iOS allows.")
            }
            Section("Audio packs") {
                Text("AeroPA doesn't include airline recordings and isn't affiliated with any airline. Packs use original scripts and the system voice, or your own original or licensed recordings.")
            }
        }
        .navigationTitle("How AeroPA works")
        .inlineTitle()
    }
}
