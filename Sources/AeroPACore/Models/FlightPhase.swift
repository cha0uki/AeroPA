import Foundation

public enum FlightPhase: String, Codable, CaseIterable, Comparable, Sendable {
    case preflight = "PREFLIGHT"
    case boarding = "BOARDING"
    case pushback = "PUSHBACK"
    case engineStart = "ENGINE_START"
    case taxi = "TAXI"
    case takeoff = "TAKEOFF"
    case initialClimb = "INITIAL_CLIMB"
    case climb = "CLIMB"
    case cruise = "CRUISE"
    case descent = "DESCENT"
    case approach = "APPROACH"
    case landing = "LANDING"
    case taxiIn = "TAXI_IN"
    case parked = "PARKED"
    case flightEnded = "FLIGHT_ENDED"

    public var order: Int { FlightPhase.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: FlightPhase, rhs: FlightPhase) -> Bool { lhs.order < rhs.order }

    public var displayName: String {
        switch self {
        case .preflight: return "Preflight"
        case .boarding: return "Boarding"
        case .pushback: return "Pushback"
        case .engineStart: return "Engine start"
        case .taxi: return "Taxi"
        case .takeoff: return "Takeoff"
        case .initialClimb: return "Initial climb"
        case .climb: return "Climb"
        case .cruise: return "Cruise"
        case .descent: return "Descent"
        case .approach: return "Approach"
        case .landing: return "Landing"
        case .taxiIn: return "Taxi in"
        case .parked: return "Parked"
        case .flightEnded: return "Flight ended"
        }
    }

    public var isAirborne: Bool {
        switch self {
        case .initialClimb, .climb, .cruise, .descent, .approach: return true
        default: return false
        }
    }

    public var next: FlightPhase? {
        let all = FlightPhase.allCases
        let i = order + 1
        return i < all.count ? all[i] : nil
    }
}

/// Something the flight-phase engine detected. Announcement and copilot
/// engines react to these instead of to raw telemetry.
public enum FlightEventKind: Equatable, Codable, Sendable, Hashable {
    case phaseChanged(from: FlightPhase, to: FlightPhase)
    case airborne
    case touchdown
    case goAround
    case passedAltitude(feet: Int, climbing: Bool)
    case manualOverride(FlightPhase)
    case flightReset

    public var key: String {
        switch self {
        case .phaseChanged(_, let to): return "phase.\(to.rawValue)"
        case .airborne: return "event.airborne"
        case .touchdown: return "event.touchdown"
        case .goAround: return "event.goAround"
        case .passedAltitude(let ft, let climbing): return "event.altitude.\(climbing ? "climb" : "descent").\(ft)"
        case .manualOverride(let p): return "event.manual.\(p.rawValue)"
        case .flightReset: return "event.reset"
        }
    }

    public var description: String {
        switch self {
        case .phaseChanged(_, let to): return to.displayName
        case .airborne: return "Airborne"
        case .touchdown: return "Touchdown"
        case .goAround: return "Go-around"
        case .passedAltitude(let ft, let climbing): return "\(climbing ? "Climbing through" : "Descending through") \(ft.formatted()) ft"
        case .manualOverride(let p): return "Manual: \(p.displayName)"
        case .flightReset: return "Flight reset"
        }
    }
}

public struct FlightEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: FlightEventKind
    public let time: TimeInterval
    public let phase: FlightPhase

    public init(kind: FlightEventKind, time: TimeInterval, phase: FlightPhase, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.time = time
        self.phase = phase
    }
}
