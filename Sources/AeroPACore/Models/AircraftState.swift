import Foundation

/// A telemetry field a provider is able to supply.
/// Engines check these before enabling rules, so a missing field disables a
/// feature instead of being replaced with a made-up value.
public enum TelemetryCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case position
    case altitudeMSL
    case groundSpeed
    case track
    case heading
    case pitch
    case roll
    /// Vertical speed (directly reported or derived from altitude samples).
    case verticalSpeed
    case indicatedAirspeed
    case onGround
    case gear
    case flaps
    case engines
    case radioAltitude
    case aircraftIdentity

    public var displayName: String {
        switch self {
        case .position: return "Position"
        case .altitudeMSL: return "Altitude (MSL)"
        case .groundSpeed: return "Ground speed"
        case .track: return "Track"
        case .heading: return "Heading"
        case .pitch: return "Pitch"
        case .roll: return "Bank"
        case .verticalSpeed: return "Vertical speed"
        case .indicatedAirspeed: return "Indicated airspeed"
        case .onGround: return "On-ground flag"
        case .gear: return "Landing gear"
        case .flaps: return "Flaps"
        case .engines: return "Engine state"
        case .radioAltitude: return "Radio altitude"
        case .aircraftIdentity: return "Aircraft type"
        }
    }
}

/// Normalised aircraft state. All units are aviation units:
/// feet, knots, feet-per-minute, degrees (0..<360 for directions).
/// Optional fields are `nil` when the provider does not supply them.
public struct AircraftState: Equatable, Sendable {
    /// Monotonic time of the sample, in seconds (provider clock).
    public var time: TimeInterval
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMSLFeet: Double?
    public var groundSpeedKnots: Double?
    public var trackDegrees: Double?
    public var headingDegrees: Double?
    public var pitchDegrees: Double?
    public var rollDegrees: Double?
    public var verticalSpeedFPM: Double?
    /// True when `verticalSpeedFPM` was derived from altitude samples.
    public var verticalSpeedIsDerived: Bool
    public var indicatedAirspeedKnots: Double?
    public var onGround: Bool?
    /// 0 = retracted, 1 = down and locked.
    public var gearPosition: Double?
    /// 0 = clean, 1 = full.
    public var flapsPosition: Double?
    public var enginesRunning: Bool?
    public var radioAltitudeFeet: Double?
    public var aircraftName: String?
    /// Name the simulator sent in the packet (e.g. the `XGPS<name>` field).
    public var simulatorName: String?

    public init(time: TimeInterval,
                latitude: Double? = nil, longitude: Double? = nil,
                altitudeMSLFeet: Double? = nil, groundSpeedKnots: Double? = nil,
                trackDegrees: Double? = nil, headingDegrees: Double? = nil,
                pitchDegrees: Double? = nil, rollDegrees: Double? = nil,
                verticalSpeedFPM: Double? = nil, verticalSpeedIsDerived: Bool = false,
                indicatedAirspeedKnots: Double? = nil, onGround: Bool? = nil,
                gearPosition: Double? = nil, flapsPosition: Double? = nil,
                enginesRunning: Bool? = nil, radioAltitudeFeet: Double? = nil,
                aircraftName: String? = nil, simulatorName: String? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMSLFeet = altitudeMSLFeet
        self.groundSpeedKnots = groundSpeedKnots
        self.trackDegrees = trackDegrees
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.verticalSpeedFPM = verticalSpeedFPM
        self.verticalSpeedIsDerived = verticalSpeedIsDerived
        self.indicatedAirspeedKnots = indicatedAirspeedKnots
        self.onGround = onGround
        self.gearPosition = gearPosition
        self.flapsPosition = flapsPosition
        self.enginesRunning = enginesRunning
        self.radioAltitudeFeet = radioAltitudeFeet
        self.aircraftName = aircraftName
        self.simulatorName = simulatorName
    }

    /// Airspeed to use for speed-based logic: real IAS when present, otherwise
    /// ground speed if the caller allows the estimate.
    public func airspeed(allowGroundSpeedEstimate: Bool) -> (knots: Double, estimated: Bool)? {
        if let ias = indicatedAirspeedKnots { return (ias, false) }
        if allowGroundSpeedEstimate, let gs = groundSpeedKnots { return (gs, true) }
        return nil
    }
}

public enum Units {
    public static let feetPerMetre = 3.280839895
    public static let knotsPerMetrePerSecond = 1.943844492

    /// Normalises any angle to 0..<360.
    public static func normalizedDegrees(_ value: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Smallest absolute difference between two directions, 0...180.
    public static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalizedDegrees(a) - normalizedDegrees(b))
        return d > 180 ? 360 - d : d
    }
}
