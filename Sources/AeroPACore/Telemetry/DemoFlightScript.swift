import Foundation

/// A simple kinematic model of a commercial flight, from gate to gate.
/// It's used by `MockTelemetryProvider` (demo mode) and by the full-flight tests.
/// The numbers are plausible for an A320-class jet, not a flight model.
public struct DemoFlightScript {
    public enum Leg: Int, CaseIterable, Codable, Sendable {
        case atGate, boarding, pushback, engineStart, taxiOut, lineUp, takeoffRoll,
             initialClimb, climb, cruise, descent, approach, rollout, taxiIn, shutdown, done

        public var title: String {
            switch self {
            case .atGate: return "At gate"
            case .boarding: return "Boarding"
            case .pushback: return "Pushback"
            case .engineStart: return "Engine start"
            case .taxiOut: return "Taxi out"
            case .lineUp: return "Line up"
            case .takeoffRoll: return "Takeoff roll"
            case .initialClimb: return "Initial climb"
            case .climb: return "Climb"
            case .cruise: return "Cruise"
            case .descent: return "Descent"
            case .approach: return "Approach"
            case .rollout: return "Rollout"
            case .taxiIn: return "Taxi in"
            case .shutdown: return "Shutdown"
            case .done: return "Complete"
            }
        }
    }

    public struct Parameters: Equatable, Sendable {
        public var originElevationFeet: Double = 300
        public var destinationElevationFeet: Double = 150
        public var cruiseAltitudeFeet: Double = 35_000
        public var cruiseDuration: TimeInterval = 900
        public var rotateSpeedKnots: Double = 145
        public var approachSpeedKnots: Double = 140
        public var runwayHeading: Double = 270
        public init() {}
    }

    public var parameters: Parameters
    public private(set) var leg: Leg = .atGate
    public private(set) var legElapsed: TimeInterval = 0
    public private(set) var time: TimeInterval = 0

    // Kinematic state
    public private(set) var altitudeFeet: Double
    public private(set) var groundSpeed: Double = 0
    public private(set) var verticalSpeed: Double = 0
    public private(set) var heading: Double = 90
    public private(set) var pitch: Double = 0
    public private(set) var roll: Double = 0
    public private(set) var movingBackward = false
    public private(set) var onGround = true
    public private(set) var gear: Double = 1
    public private(set) var flaps: Double = 0
    public private(set) var engines = false
    public private(set) var latitude = 33.3675   // Arbitrary start point.
    public private(set) var longitude = -7.5898

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
        self.altitudeFeet = parameters.originElevationFeet
    }

    /// Indicated airspeed. In this model there's no wind, so IAS equals TAS
    /// below FL100, with a crude altitude correction above it.
    public var indicatedAirspeed: Double {
        guard !onGround || groundSpeed > 30 else { return 0 }
        let altFactor = 1 + max(0, altitudeFeet) / 1000 * 0.02
        return groundSpeed / altFactor
    }

    public mutating func jump(to newLeg: Leg) {
        leg = newLeg
        legElapsed = 0
        switch newLeg {
        case .climb: if onGround { onGround = false; altitudeFeet = parameters.originElevationFeet + 3_000; groundSpeed = 250; gear = 0; flaps = 0; engines = true }
        case .cruise: onGround = false; altitudeFeet = parameters.cruiseAltitudeFeet; groundSpeed = 460; verticalSpeed = 0; gear = 0; flaps = 0; engines = true
        case .descent: onGround = false; altitudeFeet = max(altitudeFeet, 20_000); groundSpeed = 420; engines = true; gear = 0
        case .approach: onGround = false; altitudeFeet = parameters.destinationElevationFeet + 4_000; groundSpeed = 200; engines = true
        default: break
        }
    }

    /// Advances the model by `dt` seconds.
    public mutating func step(_ dt: TimeInterval) {
        guard dt > 0 else { return }
        time += dt
        legElapsed += dt
        let p = parameters
        func approach(_ value: inout Double, to target: Double, rate: Double) {
            let delta = target - value
            let maxStep = rate * dt
            value += max(-maxStep, min(maxStep, delta))
        }

        switch leg {
        case .atGate:
            groundSpeed = 0
            if legElapsed > 30 { advance() }
        case .boarding:
            if legElapsed > 60 { advance() }
        case .pushback:
            movingBackward = true
            approach(&groundSpeed, to: legElapsed < 35 ? 3 : 0, rate: 1)
            if legElapsed > 30 { heading = Units.normalizedDegrees(heading + 1.5 * dt) }
            if legElapsed > 45 && groundSpeed < 0.1 { movingBackward = false; advance() }
        case .engineStart:
            groundSpeed = 0
            if legElapsed > 5 { engines = true }
            if legElapsed > 45 { flaps = 0.25; advance() }
        case .taxiOut:
            approach(&groundSpeed, to: 15, rate: 1.5)
            approach(&heading, to: p.runwayHeading, rate: 2)
            if legElapsed > 120 { advance() }
        case .lineUp:
            approach(&groundSpeed, to: 0, rate: 3)
            heading = p.runwayHeading
            if legElapsed > 15 { advance() }
        case .takeoffRoll:
            approach(&groundSpeed, to: 180, rate: 3.5)
            if groundSpeed >= p.rotateSpeedKnots {
                approach(&pitch, to: 12, rate: 3)
                if pitch > 8 && groundSpeed > p.rotateSpeedKnots + 8 {
                    onGround = false
                    advance()
                }
            }
        case .initialClimb:
            approach(&verticalSpeed, to: 2_500, rate: 600)
            approach(&groundSpeed, to: 200, rate: 1.5)
            if legElapsed > 6 { approach(&gear, to: 0, rate: 0.15) }
            if altitudeFeet > p.originElevationFeet + 1_500 { approach(&flaps, to: 0, rate: 0.02) }
            if altitudeFeet > p.originElevationFeet + 3_200 { advance() }
        case .climb:
            approach(&pitch, to: 7, rate: 1)
            approach(&verticalSpeed, to: altitudeFeet > p.cruiseAltitudeFeet - 1_500 ? 600 : 2_000, rate: 200)
            approach(&groundSpeed, to: altitudeFeet > 10_000 ? 460 : 250, rate: 1.2)
            if altitudeFeet >= p.cruiseAltitudeFeet {
                altitudeFeet = p.cruiseAltitudeFeet
                verticalSpeed = 0
                advance()
            }
        case .cruise:
            approach(&verticalSpeed, to: 0, rate: 300)
            approach(&pitch, to: 2.5, rate: 1)
            if legElapsed > p.cruiseDuration { advance() }
        case .descent:
            approach(&verticalSpeed, to: -2_200, rate: 200)
            approach(&pitch, to: -1, rate: 1)
            approach(&groundSpeed, to: altitudeFeet < 11_000 ? 250 : 420, rate: 1.5)
            if altitudeFeet <= p.destinationElevationFeet + 4_000 { advance() }
        case .approach:
            let height = altitudeFeet - p.destinationElevationFeet
            approach(&verticalSpeed, to: height > 50 ? -750 : -150, rate: 400)
            approach(&groundSpeed, to: p.approachSpeedKnots, rate: 1.5)
            approach(&pitch, to: height > 50 ? 2.5 : 5, rate: 2)
            if height < 2_500 { approach(&gear, to: 1, rate: 0.15) }
            approach(&flaps, to: height < 2_000 ? 1 : 0.5, rate: 0.03)
            if altitudeFeet <= p.destinationElevationFeet {
                altitudeFeet = p.destinationElevationFeet
                verticalSpeed = 0
                onGround = true
                advance()
            }
        case .rollout:
            approach(&pitch, to: 0, rate: 2)
            approach(&groundSpeed, to: 15, rate: 4)
            if groundSpeed <= 16 { flaps = 0; advance() }
        case .taxiIn:
            approach(&groundSpeed, to: legElapsed > 80 ? 0 : 15, rate: 1.5)
            approach(&heading, to: 180, rate: 2)
            if legElapsed > 85 && groundSpeed < 0.1 { advance() }
        case .shutdown:
            groundSpeed = 0
            if legElapsed > 10 { engines = false }
            if legElapsed > 60 { advance() }
        case .done:
            groundSpeed = 0
        }

        if !onGround {
            altitudeFeet += verticalSpeed / 60 * dt
            roll = sin(time / 40) * 3
        } else {
            verticalSpeed = 0
            roll = 0
            altitudeFeet = leg.rawValue >= Leg.rollout.rawValue ? p.destinationElevationFeet : p.originElevationFeet
        }
        // Move along the track (crude flat-earth).
        let track = movingBackward ? Units.normalizedDegrees(heading + 180) : heading
        let nm = groundSpeed * dt / 3600
        latitude += nm / 60 * cos(track * .pi / 180)
        longitude += nm / 60 * sin(track * .pi / 180) / max(cos(latitude * .pi / 180), 0.1)
    }

    private mutating func advance() {
        if let next = Leg(rawValue: leg.rawValue + 1) {
            leg = next
            legElapsed = 0
        }
    }

    public var track: Double { movingBackward ? Units.normalizedDegrees(heading + 180) : heading }

    /// Snapshot as a full-capability state, or as an Aerofly-broadcast-equivalent one.
    public func aircraftState(emulateBroadcastFields: Bool, aircraftName: String) -> AircraftState {
        var s = AircraftState(time: time,
                              latitude: latitude, longitude: longitude,
                              altitudeMSLFeet: altitudeFeet, groundSpeedKnots: groundSpeed,
                              trackDegrees: track, headingDegrees: heading,
                              pitchDegrees: pitch, rollDegrees: roll,
                              verticalSpeedFPM: verticalSpeed, verticalSpeedIsDerived: false,
                              simulatorName: "AeroPA Demo")
        if !emulateBroadcastFields {
            s.indicatedAirspeedKnots = indicatedAirspeed
            s.onGround = onGround
            s.gearPosition = gear
            s.flapsPosition = flaps
            s.enginesRunning = engines
            s.radioAltitudeFeet = onGround ? 0 : altitudeFeet - (leg.rawValue >= Leg.descent.rawValue ? parameters.destinationElevationFeet : parameters.originElevationFeet)
            s.aircraftName = aircraftName
        } else {
            s.verticalSpeedIsDerived = true
        }
        return s
    }
}
