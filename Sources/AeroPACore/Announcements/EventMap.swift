import Foundation

/// Maps flight events to cues. It's loaded from `event_map.json`, so the
/// timing and content of the cabin "show" can change without code changes.
public struct EventMap: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rules: [Rule]

    public struct Rule: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// `FlightEventKind.key`, e.g. "phase.CRUISE" or "event.altitude.climb.10000".
        public var on: String
        public var cue: String
        /// Seconds after the event (in provider time).
        public var delay: TimeInterval?
        /// If set, the rule is dropped when the phase at fire time isn't in this list.
        public var validPhases: [FlightPhase]?
        public var priority: Int?
        /// Minimum seconds between two plays of the same cue (for repeatable rules).
        public var cooldown: TimeInterval?
        public var repeatable: Bool?
        public var category: AnnouncementCategory
        public var enabledByDefault: Bool?
        /// Seconds after the due time before the item is considered stale.
        public var maxLatency: TimeInterval?
    }
}

public enum AnnouncementCategory: String, Codable, CaseIterable, Sendable {
    case boarding, safety, crew, captain, service, arrival, chime, ambience

    public var displayName: String {
        switch self {
        case .boarding: return "Boarding & welcome"
        case .safety: return "Safety"
        case .crew: return "Crew instructions"
        case .captain: return "Captain messages"
        case .service: return "Cabin service"
        case .arrival: return "Arrival"
        case .chime: return "Chimes"
        case .ambience: return "Cabin ambience"
        }
    }
}

/// Values substituted into scripts. Bracketed segments such as
/// `[ to {destination}]` are dropped when any placeholder inside them is unknown,
/// so a script never reads "flight to ." aloud.
public struct AnnouncementContext: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) { self.values = values }

    public func render(_ template: String) -> String {
        var out = ""
        var segment = ""
        var inSegment = false
        for ch in template {
            if ch == "[" && !inSegment { inSegment = true; segment = ""; continue }
            if ch == "]" && inSegment {
                inSegment = false
                if let r = substitute(segment, strict: true) { out += r }
                continue
            }
            if inSegment { segment.append(ch) } else { out.append(ch) }
        }
        if inSegment { out += "[" + segment }
        let result = substitute(out, strict: false) ?? out
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    /// strict: returns nil if any placeholder is unknown; otherwise removes unknown ones.
    private func substitute(_ text: String, strict: Bool) -> String? {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "{", let close = text[i...].firstIndex(of: "}") {
                let key = String(text[text.index(after: i)..<close])
                if let v = values[key], !v.isEmpty { result += v }
                else if strict { return nil }
                i = text.index(after: close)
            } else {
                result.append(text[i])
                i = text.index(after: i)
            }
        }
        return result
    }
}
