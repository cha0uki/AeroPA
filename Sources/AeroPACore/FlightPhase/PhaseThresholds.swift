import Foundation

/// Every number the phase engine uses. Values are in feet, knots, fpm and seconds.
/// They're Codable so they can be tuned without code changes.
public struct PhaseThresholds: Codable, Equatable, Sendable {
    // Ground operations
    /// Start boarding automatically after the aircraft has sat still at the gate this long once the companion starts. Set it negative to make boarding manual only.
    public var autoBoardingDelay: TimeInterval = 5
    public var stationarySpeed: Double = 0.7
    public var pushbackMinSpeed: Double = 0.5
    public var pushbackMaxSpeed: Double = 8
    /// Track opposite heading means moving backwards. Requires heading data.
    public var pushbackTrackHeadingDifference: Double = 135
    public var pushbackHold: TimeInterval = 3
    /// Without engine data: infer engine start once the aircraft has stopped this long after pushback.
    public var inferredEngineStartAfterPushbackStop: TimeInterval = 8
    public var enginesRunningHold: TimeInterval = 2
    public var taxiSpeed: Double = 3
    public var taxiHold: TimeInterval = 4
    public var takeoffRollSpeed: Double = 40
    public var takeoffRollHold: TimeInterval = 2
    public var rejectedTakeoffSpeed: Double = 25
    public var rejectedTakeoffHold: TimeInterval = 5

    // Airborne
    public var liftoffHeight: Double = 100
    public var liftoffVerticalSpeed: Double = 300
    public var liftoffHold: TimeInterval = 2
    public var initialClimbEndHeight: Double = 3_000
    public var initialClimbEndHold: TimeInterval = 3
    public var cruiseVerticalSpeedBand: Double = 300
    public var cruiseHold: TimeInterval = 60
    public var cruiseMinimumHeight: Double = 6_000
    public var descentVerticalSpeed: Double = -500
    public var descentHold: TimeInterval = 30
    public var descentMinimumAltitudeLoss: Double = 1_000
    public var approachHeight: Double = 4_000
    public var approachMaxGroundSpeed: Double = 250
    public var approachFlapsThreshold: Double = 0.3
    public var approachHold: TimeInterval = 10
    public var goAroundVerticalSpeed: Double = 1_000
    public var goAroundHold: TimeInterval = 5
    public var goAroundAltitudeGain: Double = 300

    // Touchdown and after
    /// Heuristic touchdown without an on-ground flag: |VS| below this...
    public var touchdownVerticalSpeedBand: Double = 200
    /// ...while decelerating at least this hard (kt/s). Wheel braking or reversers is about 2–5 kt/s; slowing in the air is usually under 1 kt/s.
    public var touchdownDeceleration: Double = 1.5
    public var touchdownHold: TimeInterval = 2
    /// Below this ground speed an airliner can't be flying, so it's treated as a touchdown.
    public var touchdownFallbackSpeed: Double = 70
    /// With a known destination elevation, a touchdown can't be declared higher than this above it.
    public var touchdownMaxHeight: Double = 300
    public var landingToTaxiSpeed: Double = 40
    public var landingToTaxiHold: TimeInterval = 3
    public var parkedSpeed: Double = 1
    public var parkedHold: TimeInterval = 30
    public var flightEndedHold: TimeInterval = 120
    public var enginesOffHold: TimeInterval = 10

    /// Altitudes (MSL) that produce `passedAltitude` events, e.g. FL100 and the transition altitude.
    public var altitudeMarkers: [Int] = [10_000]
    /// Hysteresis that re-arms an altitude marker.
    public var altitudeMarkerHysteresis: Double = 300

    /// Minimum number of samples a condition must hold for, whatever the duration.
    /// One sample can never trigger a transition.
    public var minimumSamples = 3

    public init() {}
}

/// Time-based debouncer. A condition is "held" only after it has been
/// continuously true for `hold` seconds AND across `minimumSamples` samples.
public struct ConditionDebouncer: Sendable {
    private var since: [String: (start: TimeInterval, samples: Int)] = [:]
    public var minimumSamples: Int

    public init(minimumSamples: Int = 3) { self.minimumSamples = minimumSamples }

    public mutating func held(_ key: String, _ condition: Bool, for hold: TimeInterval, now: TimeInterval) -> Bool {
        guard condition else { since[key] = nil; return false }
        let entry = since[key] ?? (now, 0)
        let updated = (start: entry.start, samples: entry.samples + 1)
        since[key] = updated
        return now - updated.start >= hold && updated.samples >= minimumSamples
    }

    /// Time this condition has been continuously true, or nil.
    public func duration(_ key: String, now: TimeInterval) -> TimeInterval? {
        since[key].map { now - $0.start }
    }

    public mutating func clear(_ key: String) { since[key] = nil }
    public mutating func clearAll() { since.removeAll() }
}
