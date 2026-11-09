import Foundation

public enum PhaseDetectionMode: String, Codable, CaseIterable, Sendable {
    /// Telemetry drives transitions; manual overrides are still allowed.
    case automatic
    /// Only manual overrides change the phase.
    case manual
}

/// Infers the flight phase from normalised telemetry.
///
/// Principles:
/// * **Capability-aware.** Real gear, flap, engine or on-ground data is used when
///   present. Otherwise the engine falls back to kinematic heuristics that need only
///   the Aerofly broadcast fields (altitude, ground speed, track, heading).
/// * **Debounced.** Every transition must hold for a duration and for several samples.
/// * **Monotonic.** Phases only move forward, except a rejected takeoff (back to taxi),
///   a go-around (back to climb) and taxiing again after parking.
/// * **Deterministic.** All timing uses `AircraftState.time`, so tests can replay fixtures.
public final class FlightPhaseEngine {
    public var thresholds: PhaseThresholds {
        didSet { debouncer.minimumSamples = thresholds.minimumSamples }
    }
    public var mode: PhaseDetectionMode = .automatic
    public var capabilities: Set<TelemetryCapability>
    /// Destination field elevation entered by the user. Needed for reliable approach-height logic.
    public var destinationElevationFeet: Double?

    public private(set) var phase: FlightPhase = .preflight
    public private(set) var phaseEnteredAt: TimeInterval?
    /// Origin elevation captured while stationary before takeoff.
    public private(set) var originElevationFeet: Double?
    public private(set) var touchdownElevationFeet: Double?
    public private(set) var maxAltitudeFeet: Double = -.infinity
    public private(set) var lastState: AircraftState?
    public var companionActive = false

    private var debouncer: ConditionDebouncer
    private var speedHistory: [(t: TimeInterval, gs: Double)] = []
    private var lowestApproachAltitude: Double = .infinity
    private var pushbackStoppedAt: TimeInterval?
    private var didPushback = false
    private var armedMarkers: [Int: Bool] = [:] // marker -> armed for climbing(true)/descending(false)
    private var lastDescendingVSTime: TimeInterval?

    public init(thresholds: PhaseThresholds = PhaseThresholds(), capabilities: Set<TelemetryCapability>) {
        self.thresholds = thresholds
        self.capabilities = capabilities
        self.debouncer = ConditionDebouncer(minimumSamples: thresholds.minimumSamples)
    }

    // MARK: - Public API

    public func reset() -> [FlightEvent] {
        let t = lastState?.time ?? 0
        phase = .preflight
        phaseEnteredAt = t
        originElevationFeet = nil
        touchdownElevationFeet = nil
        maxAltitudeFeet = -.infinity
        debouncer.clearAll()
        speedHistory.removeAll()
        lowestApproachAltitude = .infinity
        pushbackStoppedAt = nil
        didPushback = false
        armedMarkers.removeAll()
        lastDescendingVSTime = nil
        return [FlightEvent(kind: .flightReset, time: t, phase: .preflight)]
    }

    /// Forces a phase (manual override). Allowed in both modes.
    public func forcePhase(_ newPhase: FlightPhase, at time: TimeInterval? = nil) -> [FlightEvent] {
        let t = time ?? lastState?.time ?? 0
        guard newPhase != phase else { return [] }
        var events = [FlightEvent(kind: .manualOverride(newPhase), time: t, phase: newPhase)]
        events += transition(to: newPhase, at: t)
        debouncer.clearAll()
        return events
    }

    /// Feeds one state; returns events detected (usually none).
    public func process(_ state: AircraftState) -> [FlightEvent] {
        defer { lastState = state }
        let now = state.time
        if phaseEnteredAt == nil { phaseEnteredAt = now }
        record(state)
        guard mode == .automatic else { return [] }

        var events = altitudeMarkerEvents(state)
        if let next = evaluateTransition(state) {
            events += transition(to: next, at: now)
        }
        return events
    }

    /// Best available height above the relevant runway, and whether it's trustworthy.
    public func estimatedHeightAboveGround(_ state: AircraftState) -> (feet: Double, reliable: Bool)? {
        if let ra = state.radioAltitudeFeet { return (ra, true) }
        guard let alt = state.altitudeMSLFeet else { return nil }
        if phase >= .descent || phase == .landing {
            if let dest = destinationElevationFeet { return (alt - dest, true) }
            if let origin = originElevationFeet { return (alt - origin, false) }
            return nil
        }
        if let origin = originElevationFeet { return (alt - origin, true) }
        return nil
    }

    public var hasDestinationElevation: Bool { destinationElevationFeet != nil }

    // MARK: - Bookkeeping

    private func record(_ s: AircraftState) {
        if let gs = s.groundSpeedKnots {
            speedHistory.append((s.time, gs))
            speedHistory.removeAll { $0.t < s.time - 6 }
        }
        if let alt = s.altitudeMSLFeet {
            maxAltitudeFeet = max(maxAltitudeFeet, alt)
            // Capture origin elevation while stationary on the ground before takeoff.
            if phase < .takeoff, (s.groundSpeedKnots ?? 0) < 5, s.onGround != false {
                originElevationFeet = originElevationFeet.map { $0 * 0.9 + alt * 0.1 } ?? alt
            }
            if phase == .approach { lowestApproachAltitude = min(lowestApproachAltitude, alt) }
        }
        if let vs = s.verticalSpeedFPM, vs < -300 { lastDescendingVSTime = s.time }
    }

    /// Average deceleration (kt/s, positive = slowing) over the last ~4 s.
    private func deceleration(now: TimeInterval) -> Double? {
        let window = speedHistory.filter { $0.t >= now - 4 }
        guard let first = window.first, let last = window.last, last.t - first.t >= 2 else { return nil }
        return (first.gs - last.gs) / (last.t - first.t)
    }

    private func has(_ c: TelemetryCapability) -> Bool { capabilities.contains(c) }

    private func timeInPhase(_ now: TimeInterval) -> TimeInterval { now - (phaseEnteredAt ?? now) }

    // MARK: - Transition rules

    private func evaluateTransition(_ s: AircraftState) -> FlightPhase? {
        let t = thresholds
        let now = s.time
        let gs = s.groundSpeedKnots ?? 0
        let vs = s.verticalSpeedFPM ?? 0
        let alt = s.altitudeMSLFeet ?? 0
        let heightAboveOrigin = originElevationFeet.map { alt - $0 }

        // Shared predicates
        let movingBackward: Bool = {
            guard let trk = s.trackDegrees, let hdg = s.headingDegrees else { return false }
            return gs >= t.pushbackMinSpeed && gs <= t.pushbackMaxSpeed &&
                Units.angularDifference(trk, hdg) >= t.pushbackTrackHeadingDifference
        }()
        let movingForward: Bool = {
            guard gs >= t.taxiSpeed else { return false }
            guard let trk = s.trackDegrees, let hdg = s.headingDegrees else { return true }
            return Units.angularDifference(trk, hdg) < 60
        }()
        let enginesRunning = has(.engines) ? (s.enginesRunning ?? false) : nil
        let airborne: Bool = {
            if has(.onGround), let og = s.onGround { return !og }
            guard let h = heightAboveOrigin else { return false }
            return h > t.liftoffHeight && vs > t.liftoffVerticalSpeed
        }()

        switch phase {
        case .preflight, .boarding, .pushback, .engineStart:
            // Ground phases may be skipped; the most advanced satisfied rule wins.
            if debouncer.held("takeoffRoll", gs >= t.takeoffRollSpeed, for: t.takeoffRollHold, now: now) {
                return .takeoff
            }
            if debouncer.held("taxi", movingForward && !movingBackward, for: t.taxiHold, now: now),
               enginesRunning != false {
                return .taxi
            }
            if phase < .engineStart {
                if let running = enginesRunning,
                   debouncer.held("engines", running, for: t.enginesRunningHold, now: now) {
                    // On the stand with engines running (without a pushback) also counts.
                    return .engineStart
                }
            }
            if phase < .pushback,
               debouncer.held("pushback", movingBackward, for: t.pushbackHold, now: now) {
                return .pushback
            }
            if phase == .pushback, enginesRunning == nil {
                // No engine data: infer the start once the push has stopped for a while.
                let stopped = gs < t.pushbackMinSpeed
                if debouncer.held("pushbackStopped", stopped, for: t.inferredEngineStartAfterPushbackStop, now: now) {
                    return .engineStart
                }
            }
            if phase == .preflight, companionActive, t.autoBoardingDelay >= 0,
               debouncer.held("boarding", gs < t.stationarySpeed, for: t.autoBoardingDelay, now: now) {
                return .boarding
            }
            return nil

        case .taxi:
            if debouncer.held("takeoffRoll", gs >= t.takeoffRollSpeed, for: t.takeoffRollHold, now: now) {
                return .takeoff
            }
            return nil

        case .takeoff:
            if debouncer.held("airborne", airborne, for: t.liftoffHold, now: now) { return .initialClimb }
            if debouncer.held("rejected", gs < t.rejectedTakeoffSpeed, for: t.rejectedTakeoffHold, now: now) {
                return .taxi
            }
            return nil

        case .initialClimb:
            if let h = heightAboveOrigin,
               debouncer.held("climb", h >= t.initialClimbEndHeight, for: t.initialClimbEndHold, now: now) {
                return .climb
            }
            return nil

        case .climb:
            if let h = heightAboveOrigin, h >= t.cruiseMinimumHeight,
               debouncer.held("cruise", abs(vs) < t.cruiseVerticalSpeedBand, for: t.cruiseHold, now: now) {
                return .cruise
            }
            // Short flight: no level cruise segment, straight into descent.
            if isDescending(s, now: now) { return .descent }
            return nil

        case .cruise:
            if isDescending(s, now: now) { return .descent }
            return nil

        case .descent:
            if approachConfigured(s, now: now) { return .approach }
            return nil

        case .approach:
            if debouncer.held("goAround",
                              vs >= t.goAroundVerticalSpeed && alt - lowestApproachAltitude >= t.goAroundAltitudeGain,
                              for: t.goAroundHold, now: now) {
                return .climb
            }
            if touchdownDetected(s, now: now) { return .landing }
            return nil

        case .landing:
            if debouncer.held("vacate", gs < t.landingToTaxiSpeed, for: t.landingToTaxiHold, now: now) { return .taxiIn }
            return nil

        case .taxiIn:
            let stopped = gs < t.parkedSpeed
            if let running = enginesRunning, !running,
               debouncer.held("enginesOff", stopped, for: t.enginesOffHold, now: now) {
                return .parked
            }
            if debouncer.held("parked", stopped, for: t.parkedHold, now: now) { return .parked }
            return nil

        case .parked:
            if debouncer.held("taxiAgain", gs >= t.taxiSpeed, for: t.taxiHold, now: now) { return .taxiIn }
            if let running = enginesRunning, !running,
               debouncer.held("enginesOffParked", true, for: t.enginesOffHold, now: now) {
                return .flightEnded
            }
            if timeInPhase(now) >= t.flightEndedHold && gs < t.parkedSpeed { return .flightEnded }
            return nil

        case .flightEnded:
            return nil
        }
    }

    private func isDescending(_ s: AircraftState, now: TimeInterval) -> Bool {
        let t = thresholds
        let vs = s.verticalSpeedFPM ?? 0
        let lost = maxAltitudeFeet - (s.altitudeMSLFeet ?? maxAltitudeFeet)
        return debouncer.held("descent", vs <= t.descentVerticalSpeed, for: t.descentHold, now: now)
            && lost >= t.descentMinimumAltitudeLoss
    }

    private func approachConfigured(_ s: AircraftState, now: TimeInterval) -> Bool {
        let t = thresholds
        var configured = false
        if has(.gear), let g = s.gearPosition, g > 0.9 { configured = true }
        if has(.flaps), let f = s.flapsPosition, f >= t.approachFlapsThreshold { configured = true }
        if let alt = s.altitudeMSLFeet {
            // Height above the destination if known; otherwise above the origin (documented fallback).
            let reference = destinationElevationFeet ?? originElevationFeet ?? 0
            if alt - reference <= t.approachHeight, (s.groundSpeedKnots ?? 0) <= t.approachMaxGroundSpeed {
                configured = true
            }
        }
        return debouncer.held("approach", configured, for: t.approachHold, now: now)
    }

    /// Touchdown detection. Uses the on-ground flag when the provider has one.
    /// Otherwise it looks for the signature of a landing roll: vertical speed
    /// collapsing to ~0 while decelerating harder than an aircraft can in the
    /// air, or simply being too slow to fly.
    private func touchdownDetected(_ s: AircraftState, now: TimeInterval) -> Bool {
        let t = thresholds
        if has(.onGround), let og = s.onGround {
            return debouncer.held("touchdown", og, for: 1, now: now)
        }
        let gs = s.groundSpeedKnots ?? 0
        let vs = s.verticalSpeedFPM ?? 0
        var heightOK = true
        if let dest = destinationElevationFeet, let alt = s.altitudeMSLFeet {
            heightOK = alt - dest <= t.touchdownMaxHeight
        }
        let recentlyDescending = lastDescendingVSTime.map { now - $0 < 90 } ?? false
        let decel = deceleration(now: now) ?? 0
        let rollout = heightOK && recentlyDescending && abs(vs) < t.touchdownVerticalSpeedBand && decel >= t.touchdownDeceleration
        let tooSlowToFly = heightOK && gs < t.touchdownFallbackSpeed
        return debouncer.held("touchdown", rollout || tooSlowToFly, for: t.touchdownHold, now: now)
    }

    private func altitudeMarkerEvents(_ s: AircraftState) -> [FlightEvent] {
        guard let alt = s.altitudeMSLFeet, phase.isAirborne || phase == .takeoff else { return [] }
        var events: [FlightEvent] = []
        let h = thresholds.altitudeMarkerHysteresis
        for marker in thresholds.altitudeMarkers {
            let m = Double(marker)
            // Arm direction is set when clearly on one side of the marker.
            if alt < m - h { if armedMarkers[marker] != true { armedMarkers[marker] = true } }
            else if alt > m + h { if armedMarkers[marker] != false { armedMarkers[marker] = false } }

            if armedMarkers[marker] == true, alt >= m,
               debouncer.held("marker.up.\(marker)", alt >= m, for: 1, now: s.time) {
                armedMarkers[marker] = nil
                events.append(FlightEvent(kind: .passedAltitude(feet: marker, climbing: true), time: s.time, phase: phase))
            } else if armedMarkers[marker] == false, alt <= m,
                      debouncer.held("marker.down.\(marker)", alt <= m, for: 1, now: s.time) {
                armedMarkers[marker] = nil
                events.append(FlightEvent(kind: .passedAltitude(feet: marker, climbing: false), time: s.time, phase: phase))
            }
        }
        return events
    }

    private func transition(to newPhase: FlightPhase, at time: TimeInterval) -> [FlightEvent] {
        let old = phase
        phase = newPhase
        phaseEnteredAt = time
        var events: [FlightEvent] = []
        if old == .approach && newPhase == .climb {
            events.append(FlightEvent(kind: .goAround, time: time, phase: newPhase))
            lowestApproachAltitude = .infinity
            maxAltitudeFeet = lastState?.altitudeMSLFeet ?? maxAltitudeFeet
        }
        events.append(FlightEvent(kind: .phaseChanged(from: old, to: newPhase), time: time, phase: newPhase))
        if newPhase == .initialClimb && old == .takeoff {
            events.append(FlightEvent(kind: .airborne, time: time, phase: newPhase))
        }
        if newPhase == .landing {
            touchdownElevationFeet = lastState?.altitudeMSLFeet
            events.append(FlightEvent(kind: .touchdown, time: time, phase: newPhase))
        }
        if newPhase == .pushback { didPushback = true }
        // Fresh debounce windows for the new phase; nothing carries across.
        debouncer.clearAll()
        return events
    }
}
