import Foundation

/// Aircraft-specific copilot behaviour (Resources/Shared/aircraft_profiles.json).
/// Airbus and Boeing phraseology differ ("One hundred knots" vs "Eighty knots",
/// "Positive climb" vs "Positive rate", "Spoilers" vs "Speedbrakes up").
public struct AircraftProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var manufacturer: String
    /// Typical speeds at medium weight, in knots IAS. The user can override them per flight.
    public var speeds: Speeds
    public var flapDetents: [FlapDetent]?
    public var callouts: [Callout]

    public struct Speeds: Codable, Equatable, Sendable {
        public var v1: Double
        public var vr: Double
        public var v2: Double
        public var vref: Double?
    }

    public struct FlapDetent: Codable, Equatable, Sendable {
        /// Normalised position 0–1 at or above which this detent is reported.
        public var position: Double
        public var name: String
    }

    public struct Callout: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        /// Fallback speech text (English; standard phraseology).
        public var text: String
        public var trigger: Trigger
        public var enabledByDefault: Bool?
    }

    public struct Trigger: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Airspeed rising through `knots` or through `speedRef` (v1/vr/v2).
            case airspeedIncreasing
            /// Airspeed falling through `knots` (landing rollout).
            case airspeedDecreasing
            /// Sustained climb right after liftoff.
            case positiveRate
            /// Gear telemetry transitions.
            case gearRetracted, gearExtended
            /// Flap position changed to a new detent.
            case flapsChanged
            /// Height above the runway descending through `feet`.
            case heightDescending
            /// Decision height (user setting) descending.
            case minimums
            /// `feet` above the decision height.
            case aboveMinimums
            /// MSL altitude crossing `feet` (or the transition altitude/level).
            case altitudeClimbing, altitudeDescending
            case transitionAltitude, transitionLevel
            case touchdown
            /// Follows another callout (procedural, not telemetry-based).
            case afterCallout
        }
        public var type: Kind
        public var knots: Double?
        public var speedRef: String?
        public var feet: Double?
        public var after: String?
        public var delay: TimeInterval?
        public var phases: [FlightPhase]?
        /// Turns this callout off when the provider has this capability, e.g. a
        /// procedural "Gear up" that real gear telemetry replaces.
        public var unlessCapability: TelemetryCapability?
    }
}

public struct AircraftProfileCatalog: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [AircraftProfile]

    public static func load(from url: URL) throws -> AircraftProfileCatalog {
        try JSONDecoder().decode(AircraftProfileCatalog.self, from: Data(contentsOf: url))
    }
}
