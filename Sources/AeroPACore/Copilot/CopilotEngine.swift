import Foundation

public struct CopilotSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// Use ground speed when IAS isn't available. It's no wind correction,
    /// so speed callouts can be off by the headwind component.
    public var allowGroundSpeedAsAirspeed = true
    /// Allow procedural responses ("Gear up" after "Positive rate") that no telemetry confirms.
    public var proceduralCallouts = true
    /// Decision height above the runway, in feet.
    public var minimumsHeight: Double = 200
    public var transitionAltitude: Double = 18_000
    public var transitionLevel: Double = 18_000
    public var speedOverrides: AircraftProfile.Speeds?
    /// Per-callout on/off overrides; absent means the profile's `enabledByDefault`.
    public var calloutOverrides: [String: Bool] = [:]
    public init() {}
}

/// Height above the runway, with whether it's trustworthy for callouts.
public struct HeightEstimate: Equatable, Sendable {
    public var feet: Double
    public var reliable: Bool
    public init(feet: Double, reliable: Bool) { self.feet = feet; self.reliable = reliable }
}

/// First-officer callouts driven by telemetry and the aircraft profile.
///
/// Callouts are armed per flight segment (takeoff, climb, approach, rollout)
/// and fire at most once per arming. A go-around re-arms the approach set.
/// A crossing must be seen on two consecutive samples before it fires.
public final class CopilotEngine {
    public enum Availability: Equatable, Sendable {
        case available
        case estimated(String)
        case unavailable(String)
        case disabled
    }

    public struct Fire: Equatable, Sendable {
        public var callout: AircraftProfile.Callout
        public var time: TimeInterval
        public var estimated: Bool
    }

    public var profile: AircraftProfile { didSet { reset() } }
    public var settings: CopilotSettings
    public var capabilities: Set<TelemetryCapability>
    /// True when the user has entered the destination elevation (or RA is available).
    public var approachHeightAvailable = false

    private var fired: Set<String> = []
    private var previous: AircraftState?
    private var previousHeight: HeightEstimate?
    private var pendingCrossings: [String: Int] = [:]
    private var scheduled: [(id: String, due: TimeInterval)] = []
    private var lastFlapDetent: String?
    private var positiveRateSince: TimeInterval?
    private var phase: FlightPhase = .preflight

    public init(profile: AircraftProfile, settings: CopilotSettings = CopilotSettings(), capabilities: Set<TelemetryCapability>) {
        self.profile = profile
        self.settings = settings
        self.capabilities = capabilities
    }

    public func reset() {
        fired.removeAll()
        previous = nil
        previousHeight = nil
        pendingCrossings.removeAll()
        scheduled.removeAll()
        lastFlapDetent = nil
        positiveRateSince = nil
    }

    var speeds: AircraftProfile.Speeds { settings.speedOverrides ?? profile.speeds }

    // MARK: - Availability (shown in Flight setup)

    public func availability(of c: AircraftProfile.Callout) -> Availability {
        if !(settings.calloutOverrides[c.id] ?? c.enabledByDefault ?? true) { return .disabled }
        let caps = capabilities
        if let u = c.trigger.unlessCapability, caps.contains(u) { return .unavailable("Replaced by \(u.displayName) telemetry") }
        switch c.trigger.type {
        case .airspeedIncreasing, .airspeedDecreasing:
            if caps.contains(.indicatedAirspeed) { return .available }
            if caps.contains(.groundSpeed) && settings.allowGroundSpeedAsAirspeed { return .estimated("Uses ground speed (no wind correction)") }
            return .unavailable("Needs airspeed")
        case .positiveRate:
            return caps.contains(.verticalSpeed) ? .available : .unavailable("Needs vertical speed")
        case .gearRetracted, .gearExtended:
            return caps.contains(.gear) ? .available : .unavailable("Aerofly's broadcast has no gear data")
        case .flapsChanged:
            return caps.contains(.flaps) ? .available : .unavailable("Aerofly's broadcast has no flap data")
        case .heightDescending, .minimums, .aboveMinimums:
            if caps.contains(.radioAltitude) || approachHeightAvailable { return .available }
            return .unavailable("Enter destination elevation in Flight setup")
        case .altitudeClimbing, .altitudeDescending, .transitionAltitude, .transitionLevel:
            return caps.contains(.altitudeMSL) ? .available : .unavailable("Needs altitude")
        case .touchdown:
            return .available
        case .afterCallout:
            guard let after = c.trigger.after, let parent = profile.callouts.first(where: { $0.id == after }) else {
                return .unavailable("Misconfigured")
            }
            if case .unavailable(let r) = availability(of: parent) { return .unavailable(r) }
            return settings.proceduralCallouts ? .estimated("Procedural response") : .unavailable("Procedural callouts off")
        }
    }

    private func isActive(_ c: AircraftProfile.Callout) -> (Bool, Bool) {
        guard settings.enabled else { return (false, false) }
        switch availability(of: c) {
        case .available: return (true, false)
        case .estimated: return (true, true)
        case .unavailable, .disabled: return (false, false)
        }
    }

    // MARK: - Events

    public func handle(_ event: FlightEvent) -> [Fire] {
        switch event.kind {
        case .phaseChanged(_, let to):
            phase = to
            switch to {
            case .takeoff:
                rearm(["airspeedIncreasing", "positiveRate", "gearRetracted", "afterCallout"])
            case .descent, .approach:
                rearm(["heightDescending", "minimums", "aboveMinimums", "gearExtended"])
            default: break
            }
        case .goAround:
            rearm(["heightDescending", "minimums", "aboveMinimums", "gearExtended", "touchdown", "airspeedDecreasing"])
            positiveRateSince = nil
            fired = fired.filter { id in profile.callouts.first { $0.id == id }?.trigger.type != .positiveRate }
        case .touchdown:
            for c in profile.callouts where c.trigger.type == .touchdown {
                let (on, _) = isActive(c)
                if on && !fired.contains(c.id) {
                    fired.insert(c.id)
                    scheduled.append((c.id, event.time + (c.trigger.delay ?? 0)))
                }
            }
        case .flightReset:
            reset()
        default: break
        }
        return []
    }

    private func rearm(_ kinds: [String]) {
        let ids = profile.callouts.filter { kinds.contains($0.trigger.type.rawValue) }.map(\.id)
        fired.subtract(ids)
        ids.forEach { pendingCrossings[$0] = nil }
    }

    // MARK: - Telemetry

    public func process(_ s: AircraftState, phase currentPhase: FlightPhase, height: HeightEstimate?) -> [Fire] {
        phase = currentPhase
        defer { previous = s; previousHeight = height }
        guard settings.enabled else { return [] }
        var out: [Fire] = []
        let now = s.time

        // Due scheduled callouts (touchdown sequence, procedural follow-ups).
        var keep: [(id: String, due: TimeInterval)] = []
        for item in scheduled {
            if now >= item.due, let c = profile.callouts.first(where: { $0.id == item.id }) {
                out.append(Fire(callout: c, time: now, estimated: c.trigger.type == .afterCallout))
            } else { keep.append(item) }
        }
        scheduled = keep

        guard let prev = previous else { return out }
        let speed = s.airspeed(allowGroundSpeedEstimate: settings.allowGroundSpeedAsAirspeed)
        let prevSpeed = prev.airspeed(allowGroundSpeedEstimate: settings.allowGroundSpeedAsAirspeed)

        for c in profile.callouts where !fired.contains(c.id) {
            let (active, estimated) = isActive(c)
            guard active else { continue }
            if let phases = c.trigger.phases, !phases.contains(currentPhase) { continue }
            var crossing = false
            let tr = c.trigger
            switch tr.type {
            case .airspeedIncreasing:
                guard let v = speed?.knots, let pv = prevSpeed?.knots, let target = speedTarget(tr) else { break }
                crossing = confirm(c.id, v >= target, previouslyBelow: pv < target)
            case .airspeedDecreasing:
                guard let v = speed?.knots, let pv = prevSpeed?.knots, let target = tr.knots else { break }
                crossing = confirm(c.id, v <= target, previouslyBelow: pv > target)
            case .positiveRate:
                guard currentPhase == .initialClimb || currentPhase == .takeoff, let vs = s.verticalSpeedFPM else { break }
                if vs > 300 {
                    if positiveRateSince == nil { positiveRateSince = now }
                    crossing = (now - (positiveRateSince ?? now)) >= 1 && confirm(c.id, true, previouslyBelow: true)
                } else { positiveRateSince = nil }
            case .gearRetracted:
                if let g = s.gearPosition, let pg = prev.gearPosition { crossing = confirm(c.id, g < 0.1, previouslyBelow: pg >= 0.1 || pendingCrossings[c.id] != nil) }
            case .gearExtended:
                if let g = s.gearPosition, let pg = prev.gearPosition { crossing = confirm(c.id, g > 0.9, previouslyBelow: pg <= 0.9 || pendingCrossings[c.id] != nil) }
            case .flapsChanged:
                if let f = s.flapsPosition, let detent = flapDetent(f), detent != lastFlapDetent {
                    if lastFlapDetent != nil, confirm(c.id + ".\(detent)", true, previouslyBelow: true) {
                        var spoken = c
                        spoken.text = c.text.replacingOccurrences(of: "{flaps}", with: detent)
                        out.append(Fire(callout: spoken, time: now, estimated: false))
                        lastFlapDetent = detent
                    } else if lastFlapDetent == nil { lastFlapDetent = detent }
                }
                continue // Repeatable; never marked fired.
            case .heightDescending, .minimums, .aboveMinimums:
                guard let h = height, h.reliable, let ph = previousHeight else { break }
                let target: Double
                switch tr.type {
                case .minimums: target = settings.minimumsHeight
                case .aboveMinimums: target = settings.minimumsHeight + (tr.feet ?? 100)
                default: target = tr.feet ?? 0
                }
                crossing = confirm(c.id, h.feet <= target, previouslyBelow: ph.feet > target)
            case .altitudeClimbing, .transitionAltitude:
                guard let a = s.altitudeMSLFeet, let pa = prev.altitudeMSLFeet else { break }
                let target = tr.type == .transitionAltitude ? settings.transitionAltitude : (tr.feet ?? 0)
                crossing = confirm(c.id, a >= target, previouslyBelow: pa < target)
            case .altitudeDescending, .transitionLevel:
                guard let a = s.altitudeMSLFeet, let pa = prev.altitudeMSLFeet else { break }
                let target = tr.type == .transitionLevel ? settings.transitionLevel : (tr.feet ?? 0)
                crossing = confirm(c.id, a <= target, previouslyBelow: pa > target)
            case .touchdown, .afterCallout:
                continue
            }
            if crossing {
                fired.insert(c.id)
                out.append(Fire(callout: c, time: now, estimated: estimated))
            }
        }

        // Procedural follow-ups of what fired this tick.
        for f in out {
            for follower in profile.callouts where follower.trigger.type == .afterCallout && follower.trigger.after == f.callout.id {
                let (active, _) = isActive(follower)
                if active && !fired.contains(follower.id) {
                    fired.insert(follower.id)
                    scheduled.append((follower.id, now + (follower.trigger.delay ?? 1.5)))
                }
            }
        }
        return out
    }

    /// Two-sample confirmation: the first satisfying sample, when the previous sample
    /// was strictly on the other side, arms the crossing; the second consecutive
    /// satisfying sample fires it. `previouslyBelow` means "previous sample was on the other side".
    private func confirm(_ id: String, _ condition: Bool, previouslyBelow: Bool) -> Bool {
        guard condition else { pendingCrossings[id] = nil; return false }
        if let n = pendingCrossings[id] {
            pendingCrossings[id] = n + 1
            return n + 1 >= 2
        }
        if previouslyBelow { pendingCrossings[id] = 1 }
        return false
    }

    private func speedTarget(_ t: AircraftProfile.Trigger) -> Double? {
        if let k = t.knots { return k }
        switch t.speedRef {
        case "v1": return speeds.v1
        case "vr": return speeds.vr
        case "v2": return speeds.v2
        default: return nil
        }
    }

    private func flapDetent(_ position: Double) -> String? {
        let detents = (profile.flapDetents ?? []).sorted { $0.position < $1.position }
        return detents.last(where: { position + 0.02 >= $0.position })?.name
    }
}
