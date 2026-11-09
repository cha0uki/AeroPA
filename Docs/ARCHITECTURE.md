# AeroPA architecture

```
 Aerofly FS ──UDP 49002 (XGPS/XATT text)──▶ AeroflyUDPProvider ─┐
                                                               ├─▶ SimulatorTelemetryProvider (protocol)
 DemoFlightScript ─────────────────────────▶ MockTelemetryProvider ┘         │ AircraftState (normalised, capability-tagged)
                                                                            ▼
                                                                  FlightPhaseEngine ──FlightEvent──┬──▶ AnnouncementEngine ──┐
                                                                  (debounced state machine)         └──▶ CopilotEngine ───────┤ AudioRequest
                                                                                                                              ▼
                                                                                         AudioScheduler (per-channel priority queues,
                                                                                         expiry, ducking, lead-in chimes)
                                                                                                    │ AudioOutput (protocol)
                                                                                                    ▼
                                                                                         AVAudioOutput (AVAudioEngine, 4 mixers, EQ,
                                                                                         speech-to-buffer) + AudioSessionManager
 CompanionCoordinator (ObservableObject) wires the pipeline and publishes state ──▶ SwiftUI views (no business logic)
```

## Layout

| Path | Contents |
|---|---|
| `Sources/AeroPACore/Models` | `AircraftState`, `TelemetryCapability`, `FlightPhase`, `FlightEvent` |
| `Sources/AeroPACore/Telemetry` | `ForeFlightMessageParser` (the only code that knows the wire format), `TelemetryNormalizer`, `SimulatorTelemetryProvider`, `AeroflyUDPProvider`, `MockTelemetryProvider`, `DemoFlightScript` |
| `Sources/AeroPACore/FlightPhase` | `FlightPhaseEngine`, `PhaseThresholds`, `ConditionDebouncer` |
| `Sources/AeroPACore/Announcements` | Pack manifests and library, `EventMap`, `CueResolver`, `AnnouncementEngine` |
| `Sources/AeroPACore/Copilot` | `AircraftProfile`, `CopilotEngine` |
| `Sources/AeroPACore/Audio` | `AudioTypes`, `AudioScheduler`, `AVAudioOutput` |
| `Sources/AeroPACore/Configuration` | `AppSettings`, `SettingsStore` (UserDefaults JSON) |
| `Sources/AeroPACore/Services` | `CompanionCoordinator`, `AudioSessionManager`, `FlightLogStore` (Core Data, programmatic model) |
| `AeroPA/App`, `AeroPA/Views/*` | SwiftUI app: Dashboard, Connection, Live Flight, Airlines, Audio, Settings, Flight setup, First officer, Demo |
| `AeroPA/Resources/Airlines/<id>` | Airline packs: `manifest.json`, `PA/`, `Copilot/`, `SFX/` |
| `AeroPA/Resources/Shared` | `event_map.json`, `aircraft_profiles.json`, `scripts.<lang>.json`, `GenericPack` (original synthesised chimes and ambience) |
| `Tests/AeroPACoreTests` | XCTest suites and fixtures |
| `Sources/AeroPAUDPReplay` | CLI that sends Aerofly-format datagrams to a device |

The core is a Swift package with no UIKit or SwiftUI dependency. It builds and tests on macOS as well as iOS, which keeps every major component testable without a simulator.

## Key design decisions

* **Capability-tagged telemetry.** Providers declare which fields they supply. Engines turn rules on or off from these flags, so they never make up missing data. Aerofly's broadcast supplies 8 of the 15 fields.
* **Time comes from the samples.** Engines use `AircraftState.time` (monotonic), not wall clock. Tests replay fixtures deterministically, and the UDP provider stamps samples with `TimeSource`, which can be injected.
* **Debouncing everywhere.** Every phase transition needs a hold time *and* at least 3 samples. Copilot crossings need two consecutive samples after the previous sample was strictly on the other side of the threshold.
* **Monotonic phases** with three explicit exceptions: rejected takeoff (back to taxi), go-around (back to climb), and taxiing again after parking.
* **Manifest-driven audio.** The event map refers to *cue keys* (`pa.welcome`). Packs map cue keys to files per language with weights. Missing files fall back to the shared script spoken by `AVSpeechSynthesizer` (labelled *Synthesized*), and then to an error in the timeline. The engine never hard-codes a filename.
* **Once per flight.** Announcement rules are reserved when scheduled, delayed rules are cancelled if their `validPhases` no longer match, and repeatable rules have cooldowns.
* **Two clocks, kept apart.** Flight logic runs on provider time. Audio expiry (`maxLatency`) runs on the scheduler's real clock, so a late "V1" is dropped, not spoken.
* **Dependency injection.** `CompanionCoordinator` takes the provider factory, `AudioOutput`, `SettingsStore`, `FlightLogStore` and clock. `AppEnvironment.makeCoordinator()` is the only place concrete types are chosen.
* **ObservableObject over @Observable.** This keeps the core compatible with Swift 5.8 toolchains used in CI without Xcode. The app's iOS 17 target is unaffected.
* **Core Data over SwiftData** for flight history. The model is built in code, so it works the same in the app and in tests (in-memory store).
