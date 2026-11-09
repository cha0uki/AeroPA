import Foundation
import XCTest
@testable import AeroPACore

final class FlightPhaseEngineTests: XCTestCase {
    let fullSequence: [FlightPhase] = [.preflight, .boarding, .pushback, .engineStart, .taxi, .takeoff, .initialClimb,
                                       .climb, .cruise, .descent, .approach, .landing, .taxiIn, .parked, .flightEnded]

    func testDebouncerNeverFiresOnASingleSample() {
        var d = ConditionDebouncer(minimumSamples: 3)
        XCTAssertFalse(d.held("x", true, for: 0, now: 0))
        XCTAssertFalse(d.held("x", true, for: 0, now: 0.1))
        XCTAssertTrue(d.held("x", true, for: 0, now: 0.2))
        XCTAssertFalse(d.held("x", false, for: 0, now: 0.3))
        XCTAssertFalse(d.held("x", true, for: 0, now: 0.4), "Reset after the condition breaks")
    }

    func testDebouncerRequiresDuration() {
        var d = ConditionDebouncer(minimumSamples: 1)
        XCTAssertFalse(d.held("x", true, for: 5, now: 0))
        XCTAssertFalse(d.held("x", true, for: 5, now: 4.9))
        XCTAssertTrue(d.held("x", true, for: 5, now: 5.0))
    }

    func testFullFlightWithFullTelemetry() {
        let engine = FlightPhaseEngine(capabilities: .full)
        engine.companionActive = true
        let (phases, events) = FlightFixtures.run(engine, FlightFixtures.demoStates(emulateBroadcast: false))
        XCTAssertEqual(phases, fullSequence)
        XCTAssertEqual(events.filter { $0.kind == .airborne }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .touchdown }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .passedAltitude(feet: 10_000, climbing: true) }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .passedAltitude(feet: 10_000, climbing: false) }.count, 1)
    }

    /// The real Aerofly case: only XGPS/XATT text datagrams, so no gear, flaps,
    /// engines, on-ground or IAS. VS is derived. Packets go through the real parser and normalizer.
    func testFullFlightFromBroadcastPacketsOnly() throws {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        engine.companionActive = true
        let normalizer = TelemetryNormalizer()
        var phases: [FlightPhase] = [engine.phase]
        var touchdowns = 0
        for (t, line) in FlightFixtures.demoPackets() {
            let msg = try ForeFlightMessageParser.parse(line)
            guard let state = normalizer.ingest(msg, at: t) else { continue }
            for e in engine.process(state) {
                if case .phaseChanged(_, let to) = e.kind { phases.append(to) }
                if e.kind == .touchdown { touchdowns += 1 }
            }
        }
        XCTAssertEqual(phases, fullSequence, "Broadcast-only inference must still reach every phase")
        XCTAssertEqual(touchdowns, 1)
    }

    func testNoTransitionsWhenStationaryAndCompanionInactive() {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        var events: [FlightEvent] = []
        for i in 0..<600 {
            events += engine.process(AircraftState(time: Double(i), altitudeMSLFeet: 300, groundSpeedKnots: 0,
                                                   trackDegrees: 90, headingDegrees: 90, verticalSpeedFPM: 0))
        }
        XCTAssertTrue(events.isEmpty, "Boarding only starts once the companion is active")
        XCTAssertEqual(engine.phase, .preflight)
    }

    func testSingleNoisySpeedSpikeDoesNotStartTakeoff() {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        _ = engine.forcePhase(.taxi, at: 0)
        var states: [AircraftState] = []
        for i in 0..<20 {
            let gs: Double = i == 10 ? 80 : 12  // one bad sample
            states.append(AircraftState(time: Double(i), altitudeMSLFeet: 300, groundSpeedKnots: gs, trackDegrees: 90, headingDegrees: 90, verticalSpeedFPM: 0))
        }
        _ = FlightFixtures.run(engine, states)
        XCTAssertEqual(engine.phase, .taxi)
    }

    func testRejectedTakeoffReturnsToTaxi() {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        _ = engine.forcePhase(.taxi, at: 0)
        var states: [AircraftState] = []
        var t = 0.0
        for gs in stride(from: 10.0, through: 90, by: 3) { t += 1; states.append(.init(time: t, altitudeMSLFeet: 300, groundSpeedKnots: gs, trackDegrees: 90, headingDegrees: 90, verticalSpeedFPM: 0)) }
        for gs in stride(from: 90.0, through: 5, by: -6) { t += 1; states.append(.init(time: t, altitudeMSLFeet: 300, groundSpeedKnots: gs, trackDegrees: 90, headingDegrees: 90, verticalSpeedFPM: 0)) }
        for _ in 0..<10 { t += 1; states.append(.init(time: t, altitudeMSLFeet: 300, groundSpeedKnots: 5, trackDegrees: 90, headingDegrees: 90, verticalSpeedFPM: 0)) }
        let (phases, _) = FlightFixtures.run(engine, states)
        XCTAssertEqual(Array(phases.suffix(2)), [.takeoff, .taxi])
    }

    func testGoAroundReturnsToClimbAndReapproaches() {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        engine.destinationElevationFeet = 0
        _ = engine.forcePhase(.approach, at: 0)
        var t = 0.0, alt = 2_000.0
        var states: [AircraftState] = []
        func add(_ vs: Double, _ seconds: Int, gs: Double = 150) {
            for _ in 0..<seconds { t += 1; alt += vs / 60; states.append(.init(time: t, altitudeMSLFeet: alt, groundSpeedKnots: gs, verticalSpeedFPM: vs)) }
        }
        add(-800, 60)    // descending on approach to ~1,200 ft
        add(2_000, 30)   // go-around
        add(0, 20)       // level
        add(-900, 80)    // descend again
        add(-800, 40)
        let (phases, events) = FlightFixtures.run(engine, states)
        XCTAssertTrue(events.contains { $0.kind == .goAround })
        XCTAssertTrue(phases.contains(.climb))
        XCTAssertEqual(phases.last, .approach, "Re-enters approach after the go-around: \(phases)")
    }

    func testManualModeIgnoresTelemetryButAcceptsOverrides() {
        let engine = FlightPhaseEngine(capabilities: .full)
        engine.mode = .manual
        engine.companionActive = true
        _ = FlightFixtures.run(engine, FlightFixtures.demoStates(emulateBroadcast: false).prefix(2000).map { $0 })
        XCTAssertEqual(engine.phase, .preflight)
        let ev = engine.forcePhase(.cruise, at: 10)
        XCTAssertEqual(engine.phase, .cruise)
        XCTAssertTrue(ev.contains { $0.kind == .manualOverride(.cruise) })
        XCTAssertTrue(engine.forcePhase(.cruise).isEmpty, "Forcing the current phase is a no-op")
    }

    func testResetReturnsToPreflight() {
        let engine = FlightPhaseEngine(capabilities: .full)
        _ = engine.forcePhase(.cruise, at: 0)
        let ev = engine.reset()
        XCTAssertEqual(engine.phase, .preflight)
        XCTAssertEqual(ev.first?.kind, .flightReset)
        XCTAssertNil(engine.originElevationFeet)
    }

    func testPushbackRequiresTrackOppositeHeading() {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        _ = engine.forcePhase(.boarding, at: 0)
        var states: [AircraftState] = []
        for i in 1...10 { states.append(.init(time: Double(i), altitudeMSLFeet: 300, groundSpeedKnots: 2.5, trackDegrees: 270, headingDegrees: 90, verticalSpeedFPM: 0)) }
        _ = FlightFixtures.run(engine, states)
        XCTAssertEqual(engine.phase, .pushback)
    }

    func testEachPhaseChangeEmittedOnce() {
        let engine = FlightPhaseEngine(capabilities: .full)
        engine.companionActive = true
        let (_, events) = FlightFixtures.run(engine, FlightFixtures.demoStates(emulateBroadcast: false))
        let keys = events.compactMap { e -> String? in if case .phaseChanged = e.kind { return e.kind.key } else { return nil } }
        XCTAssertEqual(keys.count, Set(keys).count, "No duplicate phase events: \(keys)")
    }

    func testHeightEstimateUsesDestinationElevationOnApproach() throws {
        let engine = FlightPhaseEngine(capabilities: .foreFlightBroadcast)
        engine.destinationElevationFeet = 1_000
        _ = engine.forcePhase(.approach, at: 0)
        let h = try XCTUnwrap(engine.estimatedHeightAboveGround(.init(time: 1, altitudeMSLFeet: 1_500)))
        XCTAssertEqual(h.feet, 500)
        XCTAssertTrue(h.reliable)
    }
}
