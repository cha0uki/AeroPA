import Foundation

public struct FlightDetails: Codable, Equatable, Sendable {
    public var flightNumber = ""
    public var originName = ""
    public var destinationName = ""
    public var captainName = ""
    /// Destination field elevation (ft). Turns on reliable approach height callouts.
    public var destinationElevationFeet: Double?
    public var cruiseAltitudeFeet: Double?
    public var plannedFlightMinutes: Int?
    public init() {}
}

public enum TelemetrySourceKind: String, Codable, CaseIterable, Sendable {
    case aerofly
    case demo
}

/// User-facing configuration, persisted as JSON in UserDefaults.
public struct AppSettings: Codable, Equatable, Sendable {
    public var airlineID = "air-france"
    public var language = "en"
    public var aircraftProfileID = "a320"
    public var flight = FlightDetails()

    public var volumes: [String: Float] = [
        AudioChannel.pa.rawValue: 0.85,
        AudioChannel.copilot.rawValue: 0.8,
        AudioChannel.ambience.rawValue: 0.35,
        AudioChannel.sfx.rawValue: 0.7
    ]
    public var announcementsEnabled = true
    public var disabledCategories: Set<AnnouncementCategory> = []
    public var ruleOverrides: [String: Bool] = [:]
    /// Speak the script with the system voice when a pack has no recording for a cue.
    public var speechFallback = true
    public var paSpeakerEffect = true
    public var copilotInterphoneEffect = true
    /// Continuous ambience is also what keeps AeroPA running in the background (see Docs/IOS_LIMITATIONS.md).
    public var ambienceEnabled = true

    public var copilot = CopilotSettings()
    public var phaseDetection: PhaseDetectionMode = .automatic
    public var thresholds = PhaseThresholds()

    public var source: TelemetrySourceKind = .aerofly
    public var udpPort: UInt16 = AeroflyUDPProvider.defaultPort
    public var demoEmulatesBroadcastFields = false
    public var demoTimeScale: Double = 4
    public var hasCompletedOnboarding = false

    public init() {}

    public func volume(_ ch: AudioChannel) -> Float { volumes[ch.rawValue] ?? 0.8 }
    public mutating func setVolume(_ v: Float, _ ch: AudioChannel) { volumes[ch.rawValue] = v }

    public func announcementContext(airlineName: String) -> AnnouncementContext {
        var v: [String: String] = ["airline": airlineName]
        if !flight.flightNumber.isEmpty { v["flightNumber"] = flight.flightNumber }
        if !flight.originName.isEmpty { v["origin"] = flight.originName }
        if !flight.destinationName.isEmpty { v["destination"] = flight.destinationName }
        if !flight.captainName.isEmpty { v["captain"] = flight.captainName }
        if let alt = flight.cruiseAltitudeFeet { v["cruiseAltitude"] = Int(alt).formatted() }
        if let mins = flight.plannedFlightMinutes, mins > 0 {
            let h = mins / 60, m = mins % 60
            v["flightTimeHours"] = "\(h)"
            v["flightTimeMinutes"] = "\(m)"
        }
        return AnnouncementContext(values: v)
    }
}

public final class SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "aeropa.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// Loads settings. Unreadable data (e.g. after a schema change) falls back to defaults; it's never a crash.
    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}
