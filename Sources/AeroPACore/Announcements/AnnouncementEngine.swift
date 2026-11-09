import Foundation

/// Resolves a cue key to a playable source, using the pack, the language and fallbacks.
public struct CueResolver {
    public var pack: AirlinePack
    public var language: String
    public var sharedScripts: [String: SharedScripts]
    public var context: AnnouncementContext
    public var allowSpeechFallback: Bool
    /// Generic pack (shipped chimes and ambience) used when the airline pack lacks a sound.
    public var fallbackPack: AirlinePack?
    public var fileManager: FileManager = .default

    public init(pack: AirlinePack, language: String, sharedScripts: [String: SharedScripts],
                context: AnnouncementContext, allowSpeechFallback: Bool, fallbackPack: AirlinePack? = nil) {
        self.fallbackPack = fallbackPack
        self.pack = pack
        self.language = language
        self.sharedScripts = sharedScripts
        self.context = context
        self.allowSpeechFallback = allowSpeechFallback
    }

    public struct Resolved: Equatable {
        public var source: AudioSource
        public var text: String?
        public var channel: AudioChannel
        public var priority: Int
        public var leadIn: AudioSource?
        public var loops: Bool
        public var usedFallback: Bool
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownCue(String)
        case missingFiles(String, [String])
        public var description: String {
            switch self {
            case .unknownCue(let c): return "No audio or script for \(c)"
            case .missingFiles(let c, let f): return "\(c): missing \(f.joined(separator: ", "))"
            }
        }
    }

    public var voiceLanguage: String {
        pack.manifest.speechVoices?[language] ?? language
    }

    /// Default channel from the cue-key namespace.
    static func defaultChannel(for cue: String) -> AudioChannel {
        if cue.hasPrefix("copilot.") { return .copilot }
        if cue.hasPrefix("ambience.") { return .ambience }
        if cue.hasPrefix("sfx.") { return .sfx }
        return .pa
    }

    public func resolve<R: RandomNumberGenerator>(_ cue: String, using rng: inout R) -> Result<Resolved, Failure> {
        let def = pack.manifest.cues?[cue]
        let channel = def?.channel ?? Self.defaultChannel(for: cue)
        let priority = def?.priority ?? (channel == .copilot ? 90 : 50)
        let leadIn: AudioSource? = def?.leadIn.flatMap { key in
            if case .success(let r) = resolveFileOnly(key) { return r }
            return nil
        }
        let loops = def?.loops ?? false

        // 1. A recorded variant in the selected language (or language-neutral).
        let variants = (def?.variants ?? []).filter { $0.language == nil || $0.language == language }
        let fileVariants = variants.filter { v in
            guard let f = v.file else { return false }
            return fileManager.fileExists(atPath: pack.url(for: f).path)
        }
        if let v = weightedPick(fileVariants, using: &rng), let f = v.file {
            return .success(Resolved(source: .file(pack.url(for: f)), text: v.text.map(context.render),
                                     channel: channel, priority: priority, leadIn: leadIn, loops: loops, usedFallback: false))
        }
        let missing = variants.compactMap(\.file)

        // 2. Synthesised speech from the pack's script, then from the shared scripts.
        if allowSpeechFallback, channel == .pa || channel == .copilot {
            var texts = variants.compactMap(\.text)
            if texts.isEmpty, pack.manifest.inheritSharedScripts ?? true {
                texts = sharedScripts[language]?.cues[cue] ?? []
            }
            if let raw = texts.randomElement(using: &rng) {
                let text = context.render(raw)
                return .success(Resolved(source: .speech(text: text, voiceLanguage: voiceLanguage), text: text,
                                         channel: channel, priority: priority, leadIn: leadIn, loops: loops, usedFallback: true))
            }
        }
        if !missing.isEmpty { return .failure(.missingFiles(cue, missing)) }
        return .failure(.unknownCue(cue))
    }

    /// For SFX and lead-ins: files only, never speech.
    public func resolveFileOnly(_ cue: String) -> Result<AudioSource, Failure> {
        var missing: [String] = []
        for candidate in [pack, fallbackPack].compactMap({ $0 }) {
            guard let def = candidate.manifest.cues?[cue] else { continue }
            let files = def.variants.filter { $0.language == nil || $0.language == language }.compactMap(\.file)
            for f in files where fileManager.fileExists(atPath: candidate.url(for: f).path) {
                return .success(.file(candidate.url(for: f)))
            }
            missing += files
        }
        return .failure(missing.isEmpty ? .unknownCue(cue) : .missingFiles(cue, missing))
    }

    /// Whether a cue loops: the airline pack's setting first, then the fallback pack's.
    public func loops(_ cue: String) -> Bool? {
        pack.manifest.cues?[cue]?.loops ?? fallbackPack?.manifest.cues?[cue]?.loops
    }

    private func weightedPick<R: RandomNumberGenerator>(_ items: [AirlinePackManifest.Variant], using rng: inout R) -> AirlinePackManifest.Variant? {
        guard !items.isEmpty else { return nil }
        let total = items.reduce(0) { $0 + max($1.weight ?? 1, 0) }
        guard total > 0 else { return items.first }
        var r = Double.random(in: 0..<total, using: &rng)
        for item in items {
            r -= max(item.weight ?? 1, 0)
            if r < 0 { return item }
        }
        return items.last
    }
}

/// Turns flight events into scheduled PA/SFX requests.
/// Owns deduplication (once per flight), cooldowns, delays and phase validity.
public final class AnnouncementEngine {
    public struct Pending: Equatable {
        public var rule: EventMap.Rule
        public var dueAt: TimeInterval
    }

    public enum Report: Equatable {
        case scheduled(ruleID: String, dueAt: TimeInterval)
        case emitted(AudioRequest, text: String?, synthesized: Bool)
        case skippedDuplicate(ruleID: String)
        case skippedCooldown(ruleID: String)
        case skippedDisabled(ruleID: String)
        case cancelled(ruleID: String, reason: String)
        case unresolved(ruleID: String, reason: String)
    }

    public var eventMap: EventMap
    public var resolver: CueResolver
    public var disabledCategories: Set<AnnouncementCategory> = []
    /// Rules switched on or off individually; overrides `enabledByDefault`.
    public var ruleOverrides: [String: Bool] = [:]
    public var enabled = true

    public private(set) var pending: [Pending] = []
    public private(set) var firedRuleIDs: Set<String> = []
    private var lastPlayedCue: [String: TimeInterval] = [:]
    private var rng: RandomNumberGenerator

    public init(eventMap: EventMap, resolver: CueResolver, rng: RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.eventMap = eventMap
        self.resolver = resolver
        self.rng = rng
    }

    public func reset() {
        pending.removeAll()
        firedRuleIDs.removeAll()
        lastPlayedCue.removeAll()
    }

    public func isRuleEnabled(_ rule: EventMap.Rule) -> Bool {
        if let o = ruleOverrides[rule.id] { return o }
        if disabledCategories.contains(rule.category) { return false }
        return rule.enabledByDefault ?? true
    }

    /// Schedules the rules matching this event.
    public func handle(_ event: FlightEvent) -> [Report] {
        if case .flightReset = event.kind { reset(); return [] }
        var reports: [Report] = []
        for rule in eventMap.rules where rule.on == event.kind.key {
            guard enabled, isRuleEnabled(rule) else { reports.append(.skippedDisabled(ruleID: rule.id)); continue }
            if firedRuleIDs.contains(rule.id) && rule.repeatable != true {
                reports.append(.skippedDuplicate(ruleID: rule.id)); continue
            }
            if pending.contains(where: { $0.rule.id == rule.id }) {
                reports.append(.skippedDuplicate(ruleID: rule.id)); continue
            }
            let due = event.time + (rule.delay ?? 0)
            pending.append(Pending(rule: rule, dueAt: due))
            // Reserve now: a repeat of the same event can't double-schedule.
            if rule.repeatable != true { firedRuleIDs.insert(rule.id) }
            reports.append(.scheduled(ruleID: rule.id, dueAt: due))
        }
        return reports
    }

    /// Releases due items. Call on every telemetry update / timer tick.
    public func tick(now: TimeInterval, phase: FlightPhase) -> (requests: [AudioRequest], reports: [Report]) {
        var requests: [AudioRequest] = []
        var reports: [Report] = []
        var keep: [Pending] = []
        for p in pending {
            guard now >= p.dueAt else { keep.append(p); continue }
            let rule = p.rule
            if let valid = rule.validPhases, !valid.contains(phase) {
                reports.append(.cancelled(ruleID: rule.id, reason: "phase is \(phase.displayName)"))
                continue
            }
            if let maxLatency = rule.maxLatency, now - p.dueAt > maxLatency {
                reports.append(.cancelled(ruleID: rule.id, reason: "too late"))
                continue
            }
            if let cd = rule.cooldown, let last = lastPlayedCue[rule.cue], now - last < cd {
                reports.append(.skippedCooldown(ruleID: rule.id))
                continue
            }
            switch resolveRequest(rule, now: now) {
            case .success(let (req, text, synth)):
                lastPlayedCue[rule.cue] = now
                requests.append(req)
                reports.append(.emitted(req, text: text, synthesized: synth))
            case .failure(let f):
                reports.append(.unresolved(ruleID: rule.id, reason: f.description))
            }
        }
        pending = keep
        return (requests, reports)
    }

    /// Plays a cue immediately (preview / manual trigger), ignoring dedup.
    public func request(forCue cue: String, now: TimeInterval) -> Result<AudioRequest, CueResolver.Failure> {
        let rule = EventMap.Rule(id: "manual.\(cue)", on: "manual", cue: cue, category: .crew)
        return resolveRequest(rule, now: now).map { $0.0 }
    }

    private func resolveRequest(_ rule: EventMap.Rule, now: TimeInterval) -> Result<(AudioRequest, String?, Bool), CueResolver.Failure> {
        var generator = AnyRNG(rng)
        defer { rng = generator.base }
        let channel = CueResolver.defaultChannel(for: rule.cue)
        if channel == .sfx || channel == .ambience {
            return resolver.resolveFileOnly(rule.cue).map { src in
                let loops = resolver.loops(rule.cue) ?? (channel == .ambience)
                let req = AudioRequest(cueKey: rule.cue, title: Self.title(for: rule.cue), channel: channel,
                                       priority: rule.priority ?? 40, source: src,
                                       maxLatency: rule.maxLatency ?? 10, loops: loops)
                return (req, nil, false)
            }
        }
        return resolver.resolve(rule.cue, using: &generator).map { r in
            let req = AudioRequest(cueKey: rule.cue, title: Self.title(for: rule.cue), channel: r.channel,
                                   priority: rule.priority ?? r.priority, source: r.source, leadIn: r.leadIn,
                                   maxLatency: rule.maxLatency ?? 120, interruptible: true, loops: r.loops)
            return (req, r.text, r.usedFallback)
        }
    }

    public static func title(for cue: String) -> String {
        let known: [String: String] = [
            "pa.boarding": "Boarding welcome", "pa.doors": "Doors armed", "pa.welcome": "Welcome aboard",
            "pa.safety": "Safety briefing", "pa.cabin_prep": "Cabin preparation", "pa.takeoff": "Seats for takeoff",
            "pa.climb": "Seatbelt sign off", "pa.cruise": "Captain at cruise", "pa.service": "Meal service",
            "pa.duty_free": "Duty-free", "pa.turbulence": "Turbulence", "pa.descent": "Top of descent",
            "pa.cabin_secure": "Prepare cabin for landing", "pa.approach": "Seats for landing",
            "pa.go_around": "Go-around explanation", "pa.arrival": "Welcome to destination",
            "pa.disarm": "Disarm doors", "pa.disembark": "Disembarkation",
            "sfx.chime": "Chime", "sfx.double_chime": "Double chime", "sfx.seatbelt": "Seatbelt sign",
            "ambience.cabin": "Cabin ambience", "sfx.engine_start": "Engine start (cabin)"
        ]
        return known[cue] ?? cue
    }
}

/// Type-erased RNG so tests can inject a seeded generator.
public struct AnyRNG: RandomNumberGenerator {
    public var base: RandomNumberGenerator
    public init(_ base: RandomNumberGenerator) { self.base = base }
    public mutating func next() -> UInt64 { base.next() }
}

/// Deterministic generator for tests and reproducible demo flights.
public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
