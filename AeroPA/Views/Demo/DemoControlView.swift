import SwiftUI
import AeroPACore

/// Developer panel: drive a simulator-free flight, override values, trigger events and inspect telemetry.
struct DemoControlView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @State private var manual = MockTelemetryProvider.ManualValues()
    @State private var mode: MockTelemetryProvider.Mode = .scripted
    @State private var paused = false

    var body: some View {
        Form {
            Section {
                Toggle("Use demo flight", isOn: Binding(
                    get: { app.settings.source == .demo },
                    set: { on in app.updateSettings { $0.source = on ? .demo : .aerofly } }))
                if app.provider.isSimulated {
                    Toggle("Aerofly fields only", isOn: app.binding(\.demoEmulatesBroadcastFields))
                    Stepper(value: app.binding(\.demoTimeScale), in: 1...32, step: 1) {
                        LabeledContent("Speed", value: "\(Int(app.settings.demoTimeScale))×")
                    }
                }
            } footer: {
                Text("“Aerofly fields only” removes airspeed, gear, flaps, engines and the on-ground flag, like the real broadcast. Use it to rehearse a real flight.")
            }

            if let mock = app.mockProvider {
                Section("Scripted flight") {
                    Picker("Mode", selection: $mode) {
                        Text("Scripted").tag(MockTelemetryProvider.Mode.scripted)
                        Text("Manual").tag(MockTelemetryProvider.Mode.manual)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { m in
                        if m == .manual { mock.captureManualFromScript(); manual = mock.manual }
                        mock.mode = m
                    }
                    LabeledContent("Current leg", value: mock.script.leg.title)
                    Toggle("Paused", isOn: $paused).onChange(of: paused) { mock.setPaused($0) }
                    Menu {
                        ForEach(DemoFlightScript.Leg.allCases, id: \.self) { leg in
                            Button(leg.title) { mock.jump(to: leg) }
                        }
                    } label: { Label("Jump to leg", systemImage: "forward.end") }
                    Button("Restart flight") { mock.restartFlight(); app.resetFlight() }
                }

                if mode == .manual {
                    Section("Manual values") {
                        SliderRow(title: "Altitude", value: $manual.altitudeFeet, range: 0...41_000, unit: "ft", step: 100)
                        SliderRow(title: "Speed", value: $manual.groundSpeedKnots, range: 0...500, unit: "kt", step: 1)
                        SliderRow(title: "Vertical speed", value: $manual.verticalSpeedFPM, range: -4_000...4_000, unit: "fpm", step: 50)
                        SliderRow(title: "Heading", value: $manual.headingDegrees, range: 0...359, unit: "°", step: 1)
                        Toggle("On ground", isOn: $manual.onGround)
                        Toggle("Gear down", isOn: $manual.gearDown)
                        Toggle("Engines running", isOn: $manual.enginesRunning)
                        SliderRow(title: "Flaps", value: $manual.flaps, range: 0...1, unit: "", step: 0.05)
                    }
                    .onChange(of: manual) { mock.manual = $0 }
                }
            }

            Section("Trigger") {
                Menu {
                    ForEach(FlightPhase.allCases, id: \.self) { p in Button(p.displayName) { app.forcePhase(p) } }
                } label: { Label("Force phase", systemImage: "hand.tap") }
                Menu {
                    ForEach(app.eventMap.rules) { r in Button(AnnouncementEngine.title(for: r.cue)) { app.preview(cue: r.cue) } }
                } label: { Label("Play announcement", systemImage: "speaker.wave.2") }
                if let profile = app.currentProfile {
                    Menu {
                        ForEach(profile.callouts) { c in Button(c.text) { app.preview(cue: "copilot.\(c.id)") } }
                    } label: { Label("Play callout", systemImage: "headphones") }
                }
                Button("Reset flight", role: .destructive) { app.resetFlight() }
            }

            Section("Telemetry inspector") {
                TelemetryInspector(state: app.aircraft)
            }
        }
        .navigationTitle("Demo & testing")
        .inlineTitle()
        .onAppear {
            if let m = app.mockProvider { mode = m.mode; manual = m.manual; paused = m.isPaused }
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(step < 1 ? String(format: "%.2f", value) : "\(Int(value)) \(unit)")
                    .font(Theme.mono(13)).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct TelemetryInspector: View {
    let state: AircraftState?

    var body: some View {
        if let s = state {
            Group {
                row("Time", String(format: "%.1f s", s.time))
                row("Lat / Lon", s.latitude.map { String(format: "%.4f, %.4f", $0, s.longitude ?? 0) } ?? "—")
                row("Altitude MSL", Format.feet(s.altitudeMSLFeet) + " ft")
                row("Ground speed", Format.knots(s.groundSpeedKnots) + " kt")
                row("IAS", s.indicatedAirspeedKnots.map { Format.knots($0) + " kt" } ?? "not available")
                row("Vertical speed", Format.fpm(s.verticalSpeedFPM) + (s.verticalSpeedIsDerived ? " (derived)" : ""))
                row("Heading / track", "\(Format.heading(s.headingDegrees)) / \(Format.heading(s.trackDegrees))")
            }
            Group {
                row("Pitch / bank", s.pitchDegrees.map { String(format: "%.1f° / %.1f°", $0, s.rollDegrees ?? 0) } ?? "—")
                row("On ground", s.onGround.map { $0 ? "yes" : "no" } ?? "not available")
                row("Gear", s.gearPosition.map { String(format: "%.0f%%", $0 * 100) } ?? "not available")
                row("Flaps", s.flapsPosition.map { String(format: "%.0f%%", $0 * 100) } ?? "not available")
                row("Engines", s.enginesRunning.map { $0 ? "running" : "off" } ?? "not available")
                row("Source", s.simulatorName ?? "—")
            }
        } else {
            Text("No telemetry").foregroundStyle(Theme.textSecondary)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).font(Theme.mono(13, weight: .regular)) }
    }
}
