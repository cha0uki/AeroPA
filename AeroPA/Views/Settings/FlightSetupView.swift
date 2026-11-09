import SwiftUI
import AeroPACore

struct FlightSetupView: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        Form {
            Section("Aircraft & airline") {
                Picker("Aircraft", selection: app.binding(\.aircraftProfileID)) {
                    ForEach(app.profiles) { Text($0.name).tag($0.id) }
                }
                Picker("Airline", selection: app.binding(\.airlineID)) {
                    ForEach(app.packs) { Text($0.manifest.name).tag($0.id) }
                }
                if let pack = app.currentPack {
                    Picker("Language", selection: app.binding(\.language)) {
                        ForEach(pack.manifest.languages, id: \.self) { l in
                            Text(Locale.current.localizedString(forLanguageCode: l) ?? l).tag(l)
                        }
                    }
                }
            }

            Section {
                TextField("Flight number (e.g. AF1234)", text: app.binding(\.flight.flightNumber))
                TextField("Origin city", text: app.binding(\.flight.originName))
                TextField("Destination city", text: app.binding(\.flight.destinationName))
                TextField("Captain's name", text: app.binding(\.flight.captainName))
            } header: {
                Text("Flight details")
            } footer: {
                Text("Used in announcements. Anything left empty is left out of the script.")
            }

            Section {
                OptionalNumberField(title: "Destination elevation", unit: "ft", value: app.binding(\.flight.destinationElevationFeet))
                OptionalNumberField(title: "Cruise altitude", unit: "ft", value: app.binding(\.flight.cruiseAltitudeFeet))
                OptionalIntField(title: "Planned flight time", unit: "min", value: app.binding(\.flight.plannedFlightMinutes))
                OptionalNumberField(title: "Transition altitude", unit: "ft", value: Binding(
                    get: { app.settings.copilot.transitionAltitude },
                    set: { v in app.updateSettings { $0.copilot.transitionAltitude = v ?? 18_000 } }))
                OptionalNumberField(title: "Transition level", unit: "ft", value: Binding(
                    get: { app.settings.copilot.transitionLevel },
                    set: { v in app.updateSettings { $0.copilot.transitionLevel = v ?? 18_000 } }))
            } header: {
                Text("Route data")
            } footer: {
                Text("Aerofly doesn't broadcast height above the runway. The destination elevation turns on approach height callouts and sharper landing detection. The origin elevation is captured automatically on the ground\(app.originElevationFeet.map { " (now \(Int($0)) ft)" } ?? "").")
            }

            Section {
                Picker("Phase detection", selection: app.binding(\.phaseDetection)) {
                    Text("Automatic").tag(PhaseDetectionMode.automatic)
                    Text("Manual").tag(PhaseDetectionMode.manual)
                }
                Toggle("Start boarding automatically", isOn: Binding(
                    get: { app.settings.thresholds.autoBoardingDelay >= 0 },
                    set: { on in app.updateSettings { $0.thresholds.autoBoardingDelay = on ? 5 : -1 } }))
                Menu {
                    ForEach(FlightPhase.allCases, id: \.self) { p in
                        Button(p.displayName) { app.forcePhase(p) }
                    }
                } label: {
                    Label("Set phase manually", systemImage: "hand.tap")
                }
                Button("Reset flight", role: .destructive) { app.resetFlight() }
            } header: {
                Text("Flight phases")
            } footer: {
                Text("Automatic detection needs several seconds of consistent telemetry before any change, so a single bad packet never triggers an announcement. Manual overrides work in both modes.")
            }
        }
        .navigationTitle("Flight setup")
        .inlineTitle()
    }
}

struct OptionalNumberField: View {
    let title: String
    let unit: String
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: $text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onSubmit(commit)
                .onChange(of: text) { _ in commit() }
            Text(unit).foregroundStyle(Theme.textTertiary)
        }
        .onAppear { text = value.map { String(Int($0)) } ?? "" }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { if value != nil { value = nil } ; return }
        if let v = Double(trimmed), v != value { value = v }
    }
}

struct OptionalIntField: View {
    let title: String
    let unit: String
    @Binding var value: Int?

    var body: some View {
        OptionalNumberField(title: title, unit: unit, value: Binding(
            get: { value.map(Double.init) },
            set: { value = $0.map { Int($0) } }))
    }
}
