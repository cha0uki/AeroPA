import Foundation
import Combine
import XCTest
@testable import AeroPACore

final class CopilotEngineTests: XCTestCase {
    func profile(_ id: String) throws -> AircraftProfile {
        try XCTUnwrap(try loadProfiles().first { $0.id == id })
    }

    /// Runs a full flight through phase engine + copilot; returns callout texts in order.
    func fly(_ profileID: String, caps: Set<TelemetryCapability>, emulate: Bool,
             destinationElevation: Double? = nil, settings: CopilotSettings = CopilotSettings()) throws -> [String] {
        let phase = FlightPhaseEngine(capabilities: caps)
        phase.companionActive = true
        phase.destinationElevationFeet = destinationElevation
        let prof = try profile(profileID)
        let cp = CopilotEngine(profile: prof, settings: settings, capabilities: caps)
        cp.approachHeightAvailable = destinationElevation != nil || caps.contains(.radioAltitude)
        var params = DemoFlightScript.Parameters()
        params.rotateSpeedKnots = prof.speeds.vr + 1 // the demo aircraft rotates at the profile's Vr
        var out: [String] = []
        for s in FlightFixtures.demoStates(emulateBroadcast: emulate, dt: 0.5, parameters: params) {
            for e in phase.process(s) { _ = cp.handle(e) }
            let h = phase.estimatedHeightAboveGround(s).map { HeightEstimate(feet: $0.feet, reliable: $0.reliable) }
            out += cp.process(s, phase: phase.phase, height: h).map(\.callout.text)
        }
        return out
    }

    func testAirbusTakeoffSequenceInOrder() throws {
        let calls = try fly("a320", caps: .full, emulate: false)
        let takeoff = Array(calls.prefix(5))
        XCTAssertEqual(takeoff, ["One hundred knots", "V one", "Rotate", "Positive climb", "Gear up"], "\(calls)")
        XCTAssertEqual(calls.filter { $0 == "Gear up" }.count, 1, "Procedural gear-up suppressed when gear telemetry exists")
        XCTAssertTrue(calls.contains("Retard"))
        XCTAssertTrue(calls.contains("Spoilers"))
        XCTAssertTrue(calls.contains("Seventy knots"))
    }

    func testBoeingUsesBoeingPhraseology() throws {
        let calls = try fly("b737", caps: .full, emulate: false)
        XCTAssertEqual(calls.first, "Eighty knots")
        XCTAssertTrue(calls.contains("Positive rate"))
        XCTAssertTrue(calls.contains("Speedbrakes up"))
        XCTAssertFalse(calls.contains("Retard"), "Boeing has no retard callout")
        XCTAssertFalse(calls.contains("One hundred knots"))
    }

    func testBroadcastOnlyDisablesUnsupportedCallouts() throws {
        let cp = CopilotEngine(profile: try profile("a320"), capabilities: .foreFlightBroadcast)
        let byID = Dictionary(uniqueKeysWithValues: (try profile("a320")).callouts.map { ($0.id, cp.availability(of: $0)) })
        if case .unavailable = byID["gear_down"] {} else { XCTFail("gear_down must be unavailable without gear data") }
        if case .unavailable = byID["flaps"] {} else { XCTFail("flaps must be unavailable") }
        if case .unavailable = byID["1000agl"] {} else { XCTFail("height callouts need destination elevation") }
        if case .estimated = byID["v1"] {} else { XCTFail("V1 uses estimated ground speed") }
        if case .estimated = byID["gear_up"] {} else { XCTFail("procedural gear up allowed") }

        var s = CopilotSettings(); s.allowGroundSpeedAsAirspeed = false
        cp.settings = s
        if case .unavailable = cp.availability(of: (try profile("a320")).callouts.first { $0.id == "v1" }!) {} else { XCTFail() }
    }

    func testBroadcastOnlyFlightWithDestinationElevation() throws {
        let calls = try fly("a320", caps: .foreFlightBroadcast, emulate: true, destinationElevation: 150)
        XCTAssertTrue(calls.starts(with: ["One hundred knots", "V one", "Rotate", "Positive climb", "Gear up"]), "\(calls)")
        XCTAssertTrue(calls.contains("One thousand, stabilized"))
        XCTAssertTrue(calls.contains("Minimum"))
        XCTAssertFalse(calls.contains("Gear down"), "No gear data → no gear-down callout")
    }

    func testBroadcastOnlyWithoutDestinationElevationSkipsHeightCallouts() throws {
        let calls = try fly("a320", caps: .foreFlightBroadcast, emulate: true)
        XCTAssertFalse(calls.contains("Five hundred"))
        XCTAssertFalse(calls.contains("Minimum"))
    }

    func testEachCalloutOncePerFlight() throws {
        for id in ["a320", "a350", "b737", "b777", "b787"] {
            let calls = try fly(id, caps: .full, emulate: false)
            let speedCalls = calls.filter { ["V one", "Rotate", "Minimums", "Minimum", "Five hundred"].contains($0) }
            XCTAssertEqual(speedCalls.count, Set(speedCalls).count, "\(id): \(calls)")
            XCTAssertTrue(calls.contains("Rotate"), "\(id) must call rotate at its own Vr: \(calls)")
        }
    }

    func testDescentCalloutsNeverFireDuringClimb() throws {
        let calls = try fly("a320", caps: .foreFlightBroadcast, emulate: true, destinationElevation: 150)
        let climb10 = try XCTUnwrap(calls.firstIndex(of: "Ten thousand"))
        let transAlt = try XCTUnwrap(calls.firstIndex(of: "Transition altitude, standard, set"))
        let transLvl = try XCTUnwrap(calls.firstIndex(of: "Transition level, Q N H set"))
        let desc10 = try XCTUnwrap(calls.firstIndex(of: "Ten thousand, lights on"))
        XCTAssertTrue(climb10 < transAlt && transAlt < transLvl && transLvl < desc10, "\(calls)")
    }

    func testCopilotDisabled() throws {
        var s = CopilotSettings(); s.enabled = false
        XCTAssertTrue(try fly("a320", caps: .full, emulate: false, settings: s).isEmpty)
    }

    func testSingleSampleCrossingDoesNotFire() throws {
        let cp = CopilotEngine(profile: try profile("a320"), capabilities: .full)
        _ = cp.handle(FlightEvent(kind: .phaseChanged(from: .taxi, to: .takeoff), time: 0, phase: .takeoff))
        var fired: [String] = []
        fired += cp.process(.init(time: 0, indicatedAirspeedKnots: 90), phase: .takeoff, height: nil).map(\.callout.id)
        fired += cp.process(.init(time: 1, indicatedAirspeedKnots: 101), phase: .takeoff, height: nil).map(\.callout.id)
        XCTAssertTrue(fired.isEmpty, "One sample over the threshold isn't enough")
        fired += cp.process(.init(time: 2, indicatedAirspeedKnots: 104), phase: .takeoff, height: nil).map(\.callout.id)
        XCTAssertEqual(fired, ["100kt"])
    }
}

final class AudioSchedulerTests: XCTestCase {
    func req(_ title: String, _ ch: AudioChannel = .pa, priority: Int = 50, latency: TimeInterval? = nil,
             interruptible: Bool = true, leadIn: AudioSource? = nil) -> AudioRequest {
        AudioRequest(cueKey: title, title: title, channel: ch, priority: priority,
                     source: .speech(text: title, voiceLanguage: "en"), leadIn: leadIn, maxLatency: latency, interruptible: interruptible)
    }

    func testQueuesByPriorityThenFIFO() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        s.enqueue(req("A"))
        s.enqueue(req("low1", priority: 10))
        s.enqueue(req("high", priority: 60))
        s.enqueue(req("low2", priority: 10))
        XCTAssertEqual(out.playedSpeechTexts, ["A"])
        out.finish(.pa); out.finish(.pa); out.finish(.pa)
        XCTAssertEqual(out.playedSpeechTexts, ["A", "high", "low1", "low2"])
    }

    func testHighPriorityInterruptsInterruptible() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        var outcomes: [AudioScheduler.Outcome] = []
        let c = s.outcomes.sink { outcomes.append($0) }
        s.enqueue(req("service", priority: 40))
        s.enqueue(req("urgent", priority: 80))
        XCTAssertEqual(out.playedSpeechTexts, ["service", "urgent"])
        XCTAssertTrue(out.stops.contains(.pa))
        XCTAssertTrue(outcomes.contains { if case .interrupted(let r) = $0 { return r.title == "service" }; return false })
        c.cancel()
    }

    func testNonInterruptibleIsNotCutOff() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        s.enqueue(req("v1", .copilot, priority: 90, interruptible: false))
        s.enqueue(req("other", .copilot, priority: 100))
        XCTAssertEqual(out.playedSpeechTexts, ["v1"])
    }

    func testExpiredItemsAreDropped() {
        let out = RecordingAudioOutput()
        let clock = FakeClock()
        let s = AudioScheduler(output: out, timeSource: clock)
        var expired: [String] = []
        let c = s.outcomes.sink { if case .expired(let r) = $0 { expired.append(r.title) } }
        s.enqueue(req("long", .copilot, priority: 90))
        s.enqueue(req("rotate", .copilot, priority: 90, latency: 1.5))
        clock.advance(3)
        out.finish(.copilot)
        XCTAssertEqual(expired, ["rotate"], "A late 'rotate' is never spoken")
        XCTAssertEqual(out.playedSpeechTexts, ["long"])
        c.cancel()
    }

    func testDucksAmbienceWhileSpeaking() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        s.enqueue(req("pa"))
        XCTAssertEqual(out.ducks[.ambience] ?? 1, s.ambienceDuckLevel, accuracy: 0.001)
        out.finish(.pa)
        XCTAssertEqual(out.ducks[.ambience] ?? 0, 1, accuracy: 0.001)
    }

    func testPADucksUnderCopilot() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        s.enqueue(req("pa"))
        s.enqueue(req("v1", .copilot, priority: 90))
        XCTAssertEqual(out.ducks[.pa] ?? 1, s.paDuckLevelForCopilot, accuracy: 0.001)
    }

    func testLeadInPlaysBeforeAnnouncementOnSFX() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        let chime = AudioSource.file(URL(fileURLWithPath: "/chime.wav"))
        s.enqueue(req("welcome", leadIn: chime))
        XCTAssertEqual(out.plays.map(\.channel), [.sfx])
        out.finish(.sfx)
        XCTAssertEqual(out.plays.map(\.channel), [.sfx, .pa])
    }

    func testFailedPlaybackMovesToNextItem() {
        let out = RecordingAudioOutput()
        out.failFiles = true
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        var failed = 0
        let c = s.outcomes.sink { if case .failed = $0 { failed += 1 } }
        s.enqueue(AudioRequest(cueKey: "x", title: "x", channel: .pa, priority: 50, source: .file(URL(fileURLWithPath: "/missing.m4a"))))
        s.enqueue(req("next"))
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(out.playedSpeechTexts, ["next"])
        c.cancel()
    }

    func testSuspendAndResume() {
        let out = RecordingAudioOutput()
        let s = AudioScheduler(output: out, timeSource: FakeClock())
        s.enqueue(req("a"))
        s.suspend()
        s.enqueue(req("b"))
        XCTAssertEqual(out.playedSpeechTexts, ["a"], "Nothing starts during an interruption")
        s.resume()
        XCTAssertEqual(out.playedSpeechTexts, ["a", "b"])
    }
}

final class CompanionIntegrationTests: XCTestCase {
    func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }

    func makeCoordinator(output: RecordingAudioOutput, mock: MockTelemetryProvider) -> CompanionCoordinator {
        let defaults = UserDefaults(suiteName: "aeropa-tests-\(UUID().uuidString)") ?? .standard
        let store = SettingsStore(defaults: defaults)
        var s = AppSettings()
        s.source = .demo
        s.airlineID = "air-france"
        s.language = "en"
        s.flight.destinationName = "Casablanca"
        s.flight.destinationElevationFeet = 150
        store.save(s)
        let locations = ResourceLocations(bundledAirlines: TestPaths.airlines, shared: TestPaths.shared, userAirlines: nil)
        return CompanionCoordinator(locations: locations, settingsStore: store, logStore: FlightLogStore(inMemory: true),
                                    output: output, realClock: FakeClock(), providerFactory: { _, _ in mock })
    }

    func testDemoFlightProducesOrderedAnnouncementsAndCallouts() {
        let output = RecordingAudioOutput()
        output.autoComplete = true
        let mock = MockTelemetryProvider(emulateBroadcastFields: false)
        let c = makeCoordinator(output: output, mock: mock)
        c.startMonitoring()
        c.startCompanion()
        mock.disconnect() // drive manually instead of the timer
        var guardCount = 0
        while c.phase != .flightEnded && guardCount < 20_000 {
            mock.advance(by: 1)
            pump()
            guardCount += 1
        }
        for _ in 0..<60 { mock.advance(by: 1); pump() } // let post-shutdown PAs fall due
        XCTAssertEqual(c.phase, .flightEnded)
        let announcements = c.timeline.filter { $0.kind == .announcement }.map(\.title)
        let expectedOrder = ["Boarding welcome", "Doors armed", "Welcome aboard", "Safety briefing", "Cabin preparation",
                             "Seats for takeoff", "Seatbelt sign off", "Captain at cruise", "Meal service",
                             "Top of descent", "Prepare cabin for landing", "Seats for landing",
                             "Welcome to destination", "Disarm doors", "Disembarkation"]
        XCTAssertEqual(announcements, expectedOrder, "\(announcements)")
        XCTAssertTrue(output.playedSpeechTexts.contains { $0.contains("Casablanca") }, "Placeholders filled from flight details")
        XCTAssertTrue(c.timeline.contains { $0.kind == .callout && $0.title == "V one" })
        XCTAssertTrue(output.plays.contains { $0.channel == .ambience && $0.loops }, "Ambience loop started")
        XCTAssertEqual(c.recentFlights().count, 1, "Flight persisted to Core Data")
    }

    func testCompanionInactiveDoesNotAnnounce() {
        let output = RecordingAudioOutput()
        let mock = MockTelemetryProvider()
        let c = makeCoordinator(output: output, mock: mock)
        c.startMonitoring()
        mock.disconnect()
        for _ in 0..<600 { mock.advance(by: 1); pump() }
        XCTAssertNotNil(c.aircraft, "Telemetry is monitored before the companion starts")
        XCTAssertTrue(output.plays.isEmpty)
        XCTAssertEqual(c.phase, .preflight)
    }

    func testResetFlightClearsState() {
        let output = RecordingAudioOutput()
        output.autoComplete = true
        let mock = MockTelemetryProvider()
        let c = makeCoordinator(output: output, mock: mock)
        c.startMonitoring(); c.startCompanion(); mock.disconnect()
        c.forcePhase(.cruise)
        XCTAssertEqual(c.phase, .cruise)
        c.resetFlight()
        XCTAssertEqual(c.phase, .preflight)
    }

    func testDemoProviderIsNeverReportedAsAerofly() {
        let mock = MockTelemetryProvider()
        XCTAssertTrue(mock.isSimulated)
        XCTAssertFalse(AeroflyUDPProvider().isSimulated)
    }

    func testFlightLogStoreRoundTrip() {
        let store = FlightLogStore(inMemory: true)
        let rec = FlightRecordSummary(id: UUID(), startedAt: Date(), endedAt: nil, airline: "A", aircraft: "B", source: "C",
                                      entries: [TimelineEntry(kind: .phase, title: "Cruise")])
        store.save(rec)
        XCTAssertEqual(store.recent().first?.entries.first?.title, "Cruise")
        store.deleteAll()
        XCTAssertTrue(store.recent().isEmpty)
    }
}
