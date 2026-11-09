import Foundation
import XCTest
@testable import AeroPACore

enum TestPaths {
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures = testsDir.appendingPathComponent("Fixtures")
    static let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    static let resources = repoRoot.appendingPathComponent("AeroPA/Resources")
    static let shared = resources.appendingPathComponent("Shared")
    static let airlines = resources.appendingPathComponent("Airlines")

    static func fixtureLines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
    }
}

final class FakeClock: TimeSource {
    var now: TimeInterval = 1_000
    func advance(_ s: TimeInterval) { now += s }
}

/// Records everything; completes playback only when told to (or immediately).
final class RecordingAudioOutput: AudioOutput {
    struct Play: Equatable { var source: AudioSource; var channel: AudioChannel; var loops: Bool }
    var plays: [Play] = []
    var stops: [AudioChannel] = []
    var volumes: [AudioChannel: Float] = [:]
    var ducks: [AudioChannel: Float] = [:]
    var autoComplete = false
    var failFiles = false
    private var completions: [AudioChannel: [(Result<Void, AudioPlaybackError>) -> Void]] = [:]

    func play(_ source: AudioSource, on channel: AudioChannel, loops: Bool,
              completion: @escaping (Result<Void, AudioPlaybackError>) -> Void) {
        plays.append(Play(source: source, channel: channel, loops: loops))
        if failFiles, case .file(let u) = source { completion(.failure(.fileMissing(u.lastPathComponent))); return }
        if autoComplete && !loops { completion(.success(())) } else { completions[channel, default: []].append(completion) }
    }
    func finish(_ channel: AudioChannel) {
        guard var list = completions[channel], !list.isEmpty else { return }
        let c = list.removeFirst()
        completions[channel] = list
        c(.success(()))
    }
    func stop(channel: AudioChannel, fadeDuration: TimeInterval) { stops.append(channel); completions[channel] = [] }
    func setVolume(_ volume: Float, for channel: AudioChannel) { volumes[channel] = volume }
    func setDuck(_ multiplier: Float, for channel: AudioChannel, fadeDuration: TimeInterval) { ducks[channel] = multiplier }
    func stopAll() { completions.removeAll() }

    var playedSpeechTexts: [String] {
        plays.compactMap { if case .speech(let t, _) = $0.source { return t } else { return nil } }
    }
}

enum FlightFixtures {
    /// Runs the demo script and returns states every `dt` seconds.
    static func demoStates(emulateBroadcast: Bool, dt: TimeInterval = 0.5,
                           parameters: DemoFlightScript.Parameters = .init(),
                           maxTime: TimeInterval = 6 * 3600) -> [AircraftState] {
        var script = DemoFlightScript(parameters: parameters)
        var out: [AircraftState] = []
        while script.leg != .done && script.time < maxTime {
            script.step(dt)
            out.append(script.aircraftState(emulateBroadcastFields: emulateBroadcast, aircraftName: "A320"))
        }
        for _ in 0..<Int(200 / dt) { script.step(dt); out.append(script.aircraftState(emulateBroadcastFields: emulateBroadcast, aircraftName: "A320")) }
        return out
    }

    /// Encodes the demo flight as ForeFlight datagrams, as Aerofly would send them.
    /// Returns (time, datagram) pairs: XGPS at 1 Hz, XATT at 4 Hz.
    static func demoPackets(parameters: DemoFlightScript.Parameters = .init()) -> [(TimeInterval, String)] {
        var script = DemoFlightScript(parameters: parameters)
        var out: [(TimeInterval, String)] = []
        var tick = 0
        while script.leg != .done {
            script.step(0.25)
            tick += 1
            let s = script
            out.append((s.time, String(format: "XATTAerofly FS 4,%.1f,%.1f,%.1f", s.heading, s.pitch, s.roll)))
            if tick % 4 == 0 {
                out.append((s.time, String(format: "XGPSAerofly FS 4,%.6f,%.6f,%.1f,%.1f,%.2f",
                                           s.longitude, s.latitude, s.altitudeFeet / Units.feetPerMetre,
                                           s.track, s.groundSpeed / Units.knotsPerMetrePerSecond)))
            }
        }
        for i in 0..<400 {
            script.step(0.5)
            let s = script
            if i % 2 == 0 {
                out.append((s.time, String(format: "XGPSAerofly FS 4,%.6f,%.6f,%.1f,%.1f,%.2f",
                                           s.longitude, s.latitude, s.altitudeFeet / Units.feetPerMetre, s.track, 0.0)))
            }
        }
        return out
    }

    /// Runs states through a phase engine, returning the phase sequence and all events.
    static func run(_ engine: FlightPhaseEngine, _ states: [AircraftState]) -> (phases: [FlightPhase], events: [FlightEvent]) {
        var phases: [FlightPhase] = [engine.phase]
        var events: [FlightEvent] = []
        for s in states {
            let e = engine.process(s)
            events += e
            for ev in e { if case .phaseChanged(_, let to) = ev.kind { phases.append(to) } }
        }
        return (phases, events)
    }
}

func loadProfiles() throws -> [AircraftProfile] {
    try AircraftProfileCatalog.load(from: TestPaths.shared.appendingPathComponent("aircraft_profiles.json")).profiles
}

func loadEventMap() throws -> EventMap {
    try JSONDecoder().decode(EventMap.self, from: Data(contentsOf: TestPaths.shared.appendingPathComponent("event_map.json")))
}
