import Foundation

/// Fuses the separately arriving XGPS and XATT messages into one
/// `AircraftState`, converts units and derives vertical speed.
///
/// Vertical speed isn't on the wire, so it's the least-squares slope of
/// altitude over a short sliding window. A plain two-point difference would
/// be dominated by the ~1 ft quantisation of 1 Hz GPS samples.
public final class TelemetryNormalizer {
    public struct Configuration: Equatable {
        /// Seconds of altitude history used for the vertical-speed slope.
        public var verticalSpeedWindow: TimeInterval = 3.0
        /// Minimum samples in the window before a VS value is published.
        public var minimumVerticalSpeedSamples = 2
        /// Attitude older than this is dropped from the fused state.
        public var attitudeMaxAge: TimeInterval = 3.0
        public init() {}
    }

    public var configuration: Configuration
    private var lastGPS: (message: ForeFlightMessage.GPS, time: TimeInterval)?
    private var lastAttitude: (message: ForeFlightMessage.Attitude, time: TimeInterval)?
    private var altitudeHistory: [(t: TimeInterval, ft: Double)] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func reset() {
        lastGPS = nil
        lastAttitude = nil
        altitudeHistory.removeAll()
    }

    /// Ingests one message and returns the updated fused state, or `nil` when
    /// there isn't a position fix yet (attitude alone isn't a usable state).
    @discardableResult
    public func ingest(_ message: ForeFlightMessage, at time: TimeInterval) -> AircraftState? {
        switch message {
        case .gps(let gps):
            lastGPS = (gps, time)
            let ft = gps.altitudeMetres * Units.feetPerMetre
            altitudeHistory.append((time, ft))
            let cutoff = time - configuration.verticalSpeedWindow
            altitudeHistory.removeAll { $0.t < cutoff }
        case .attitude(let att):
            lastAttitude = (att, time)
        case .traffic:
            return nil // Other aircraft; not our own state.
        }
        return currentState(at: time)
    }

    public func currentState(at time: TimeInterval) -> AircraftState? {
        guard let (gps, _) = lastGPS else { return nil }
        var state = AircraftState(time: time)
        state.simulatorName = gps.simulatorName
        state.latitude = gps.latitude
        state.longitude = gps.longitude
        state.altitudeMSLFeet = gps.altitudeMetres * Units.feetPerMetre
        state.groundSpeedKnots = gps.groundSpeedMetresPerSecond * Units.knotsPerMetrePerSecond
        state.trackDegrees = gps.trackDegrees
        if let (att, t) = lastAttitude, time - t <= configuration.attitudeMaxAge {
            state.headingDegrees = att.headingDegrees
            state.pitchDegrees = att.pitchDegrees
            state.rollDegrees = att.rollDegrees
        }
        if let vs = derivedVerticalSpeed() {
            state.verticalSpeedFPM = vs
            state.verticalSpeedIsDerived = true
        }
        return state
    }

    /// Least-squares slope (ft/s) of the altitude window, as ft/min.
    func derivedVerticalSpeed() -> Double? {
        let pts = altitudeHistory
        guard pts.count >= configuration.minimumVerticalSpeedSamples,
              let first = pts.first, let last = pts.last, last.t - first.t > 0.2 else { return nil }
        let n = Double(pts.count)
        let meanT = pts.reduce(0) { $0 + $1.t } / n
        let meanA = pts.reduce(0) { $0 + $1.ft } / n
        var num = 0.0, den = 0.0
        for p in pts {
            num += (p.t - meanT) * (p.ft - meanA)
            den += (p.t - meanT) * (p.t - meanT)
        }
        guard den > 0 else { return nil }
        return num / den * 60
    }
}

/// Capabilities of the Aerofly broadcast, per Docs/AEROFLY_TELEMETRY.md.
public extension Set where Element == TelemetryCapability {
    static let foreFlightBroadcast: Set<TelemetryCapability> = [
        .position, .altitudeMSL, .groundSpeed, .track, .heading, .pitch, .roll, .verticalSpeed
    ]
    static let full = Set(TelemetryCapability.allCases)
}
