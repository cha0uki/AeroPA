import Foundation

/// Messages of the ForeFlight simulator protocol, which is what Aerofly's
/// "Broadcast flight info to IP address" feature sends. Units are as on the wire.
/// See Docs/AEROFLY_TELEMETRY.md.
public enum ForeFlightMessage: Equatable, Sendable {
    public struct GPS: Equatable, Sendable {
        public var simulatorName: String
        public var longitude: Double
        public var latitude: Double
        public var altitudeMetres: Double
        public var trackDegrees: Double
        public var groundSpeedMetresPerSecond: Double
    }

    public struct Attitude: Equatable, Sendable {
        public var simulatorName: String
        public var headingDegrees: Double
        public var pitchDegrees: Double
        public var rollDegrees: Double
    }

    public struct Traffic: Equatable, Sendable {
        public var simulatorName: String
        public var icaoAddress: String
        public var latitude: Double
        public var longitude: Double
        public var altitudeFeet: Double
        public var verticalSpeedFPM: Double
        public var airborne: Bool
        public var headingDegrees: Double
        public var speedKnots: Double
        public var callsign: String
    }

    case gps(GPS)
    case attitude(Attitude)
    case traffic(Traffic)

    public var simulatorName: String {
        switch self {
        case .gps(let g): return g.simulatorName
        case .attitude(let a): return a.simulatorName
        case .traffic(let t): return t.simulatorName
        }
    }

    public var typeKey: String {
        switch self {
        case .gps: return "XGPS"
        case .attitude: return "XATT"
        case .traffic: return "XTRAFFIC"
        }
    }
}

public enum PacketValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case tooLarge(Int)
    case notText
    case unknownMessageType(String)
    case missingFields(type: String, expected: Int, got: Int)
    case invalidNumber(field: String, value: String)
    case outOfRange(field: String, value: Double)

    public var description: String {
        switch self {
        case .empty: return "Empty datagram"
        case .tooLarge(let n): return "Datagram too large (\(n) bytes)"
        case .notText: return "Not ASCII/UTF-8 text"
        case .unknownMessageType(let p): return "Unknown message type “\(p)”"
        case .missingFields(let t, let e, let g): return "\(t): expected \(e) fields, got \(g)"
        case .invalidNumber(let f, let v): return "Invalid number for \(f): “\(v)”"
        case .outOfRange(let f, let v): return "\(f) out of range (\(v))"
        }
    }

    /// Stable key for counting rejections in diagnostics.
    public var reasonKey: String {
        switch self {
        case .empty: return "empty"
        case .tooLarge: return "tooLarge"
        case .notText: return "notText"
        case .unknownMessageType: return "unknownType"
        case .missingFields: return "missingFields"
        case .invalidNumber: return "invalidNumber"
        case .outOfRange: return "outOfRange"
        }
    }
}

/// Stateless, strict parser for one UDP datagram. Rejects instead of guessing.
public enum ForeFlightMessageParser {
    public static let maxDatagramSize = 512

    public static func parse(_ data: Data) throws -> ForeFlightMessage {
        guard !data.isEmpty else { throw PacketValidationError.empty }
        guard data.count <= maxDatagramSize else { throw PacketValidationError.tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw PacketValidationError.notText }
        return try parse(text)
    }

    public static func parse(_ rawText: String) throws -> ForeFlightMessage {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !text.isEmpty else { throw PacketValidationError.empty }
        // Order matters: "XTRAFFIC" must be tested before shorter prefixes.
        if text.hasPrefix("XTRAFFIC") { return try parseTraffic(text) }
        if text.hasPrefix("XGPS") { return try parseGPS(text) }
        if text.hasPrefix("XATT") { return try parseAttitude(text) }
        throw PacketValidationError.unknownMessageType(String(text.prefix(8)))
    }

    // MARK: - Message types

    private static func fields(_ text: String, prefix: String) -> [String] {
        String(text.dropFirst(prefix.count))
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseGPS(_ text: String) throws -> ForeFlightMessage {
        let f = fields(text, prefix: "XGPS")
        guard f.count >= 6 else { throw PacketValidationError.missingFields(type: "XGPS", expected: 6, got: f.count) }
        let lon = try number(f[1], "longitude", range: -180...180)
        let lat = try number(f[2], "latitude", range: -90...90)
        let alt = try number(f[3], "altitude", range: -500...25_000)
        let trk = try number(f[4], "track", range: -360...360)
        let gs = try number(f[5], "groundSpeed", range: 0...600)
        return .gps(.init(simulatorName: f[0], longitude: lon, latitude: lat, altitudeMetres: alt,
                          trackDegrees: Units.normalizedDegrees(trk), groundSpeedMetresPerSecond: gs))
    }

    private static func parseAttitude(_ text: String) throws -> ForeFlightMessage {
        let f = fields(text, prefix: "XATT")
        guard f.count >= 4 else { throw PacketValidationError.missingFields(type: "XATT", expected: 4, got: f.count) }
        let hdg = try number(f[1], "heading", range: -360...360)
        let pitch = try number(f[2], "pitch", range: -90...90)
        let roll = try number(f[3], "roll", range: -180...180)
        return .attitude(.init(simulatorName: f[0], headingDegrees: Units.normalizedDegrees(hdg),
                               pitchDegrees: pitch, rollDegrees: roll))
    }

    private static func parseTraffic(_ text: String) throws -> ForeFlightMessage {
        let f = fields(text, prefix: "XTRAFFIC")
        guard f.count >= 10 else { throw PacketValidationError.missingFields(type: "XTRAFFIC", expected: 10, got: f.count) }
        let lat = try number(f[2], "latitude", range: -90...90)
        let lon = try number(f[3], "longitude", range: -180...180)
        let alt = try number(f[4], "altitude", range: -2_000...80_000)
        let vs = try number(f[5], "verticalSpeed", range: -30_000...30_000)
        let airborne = try number(f[6], "airborne", range: 0...1)
        let hdg = try number(f[7], "heading", range: -360...360)
        let spd = try number(f[8], "speed", range: 0...2_000)
        return .traffic(.init(simulatorName: f[0], icaoAddress: f[1], latitude: lat, longitude: lon,
                              altitudeFeet: alt, verticalSpeedFPM: vs, airborne: airborne >= 0.5,
                              headingDegrees: Units.normalizedDegrees(hdg), speedKnots: spd, callsign: f[9]))
    }

    private static func number(_ s: String, _ field: String, range: ClosedRange<Double>) throws -> Double {
        guard let v = Double(s), v.isFinite else { throw PacketValidationError.invalidNumber(field: field, value: s) }
        guard range.contains(v) else { throw PacketValidationError.outOfRange(field: field, value: v) }
        return v
    }
}
