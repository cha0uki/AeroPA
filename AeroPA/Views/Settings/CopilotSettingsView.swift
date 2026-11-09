import SwiftUI
import AeroPACore

struct CopilotSettingsView: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("First-officer callouts", isOn: app.binding(\.copilot.enabled))
                Toggle("Use ground speed as airspeed", isOn: app.binding(\.copilot.allowGroundSpeedAsAirspeed))
                Toggle("Procedural responses", isOn: app.binding(\.copilot.proceduralCallouts))
                Stepper(value: app.binding(\.copilot.minimumsHeight), in: 0...1_000, step: 10) {
                    LabeledContent("Minimums", value: "\(Int(app.settings.copilot.minimumsHeight)) ft")
                }
            } footer: {
                Text("Aerofly doesn't broadcast airspeed, so speed callouts use ground speed and can be early or late by the wind component. Procedural responses, such as “Gear up” after “Positive rate”, follow the previous callout rather than gear telemetry.")
            }

            if let profile = app.currentProfile {
                Section {
                    LabeledContent("V1", value: "\(Int(profile.speeds.v1)) kt")
                    LabeledContent("VR", value: "\(Int(profile.speeds.vr)) kt")
                    LabeledContent("V2", value: "\(Int(profile.speeds.v2)) kt")
                } header: {
                    Text("\(profile.name) speeds")
                } footer: {
                    Text("Typical medium-weight values.")
                }
            }

            Section("Callouts") {
                ForEach(app.copilotAvailability(), id: \.0.id) { callout, availability in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(callout.text)
                            Text(reason(availability)).font(.system(size: 12)).foregroundStyle(color(availability))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { app.settings.copilot.calloutOverrides[callout.id] ?? callout.enabledByDefault ?? true },
                            set: { on in app.updateSettings { $0.copilot.calloutOverrides[callout.id] = on } }))
                        .labelsHidden()
                    }
                }
            }
        }
        .navigationTitle("First officer")
        .inlineTitle()
    }

    private func reason(_ a: CopilotEngine.Availability) -> String {
        switch a {
        case .available: return "Available"
        case .estimated(let r): return r
        case .unavailable(let r): return r
        case .disabled: return "Off"
        }
    }

    private func color(_ a: CopilotEngine.Availability) -> Color {
        switch a {
        case .available: return Theme.positive
        case .estimated: return Theme.caution
        case .unavailable, .disabled: return Theme.textTertiary
        }
    }
}

struct AnnouncementPreferencesView: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Passenger announcements", isOn: app.binding(\.announcementsEnabled))
            }
            Section("Categories") {
                ForEach(AnnouncementCategory.allCases.filter { $0 != .ambience }, id: \.self) { cat in
                    Toggle(cat.displayName, isOn: Binding(
                        get: { !app.settings.disabledCategories.contains(cat) },
                        set: { on in app.updateSettings { if on { $0.disabledCategories.remove(cat) } else { $0.disabledCategories.insert(cat) } } }))
                }
            }
            Section {
                ForEach(app.eventMap.rules) { rule in
                    Toggle(isOn: Binding(
                        get: { app.settings.ruleOverrides[rule.id] ?? (!app.settings.disabledCategories.contains(rule.category) && (rule.enabledByDefault ?? true)) },
                        set: { on in app.updateSettings { $0.ruleOverrides[rule.id] = on } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AnnouncementEngine.title(for: rule.cue))
                            Text(trigger(rule)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Individual announcements")
            } footer: {
                Text("Each announcement plays at most once per flight. Delayed announcements are cancelled if the flight has moved on, so you'll never hear the meal service during descent.")
            }
        }
        .navigationTitle("Announcements")
        .inlineTitle()
    }

    private func trigger(_ r: EventMap.Rule) -> String {
        let event = r.on.replacingOccurrences(of: "phase.", with: "")
            .replacingOccurrences(of: "event.altitude.climb.", with: "Climbing through ")
            .replacingOccurrences(of: "event.altitude.descent.", with: "Descending through ")
            .replacingOccurrences(of: "event.", with: "")
        let phaseName = FlightPhase(rawValue: event)?.displayName ?? event
        let delay = Int(r.delay ?? 0)
        return delay > 0 ? "\(phaseName) + \(delay >= 60 ? "\(delay / 60) min" : "\(delay) s")" : phaseName
    }
}
