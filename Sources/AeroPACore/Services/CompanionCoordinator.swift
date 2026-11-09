import Foundation
import Combine

/// Where bundled and user resources live.
public struct ResourceLocations {
    public var bundledAirlines: URL?
    public var shared: URL?
    public var userAirlines: URL?

    public init(bundledAirlines: URL?, shared: URL?, userAirlines: URL?) {
        self.bundledAirlines = bundledAirlines
        self.shared = shared
        self.userAirlines = userAirlines
    }

    public var eventMapURL: URL? { shared?.appendingPathComponent("event_map.json") }
    public var profilesURL: URL? { shared?.appendingPathComponent("aircraft_profiles.json") }
    public var genericPackURL: URL? { shared?.appendingPathComponent("GenericPack") }
}

/// Wires telemetry → phase engine → announcement / copilot engines → audio scheduler,
/// and publishes state for SwiftUI. Main-thread confined. The views hold no
/// business logic; they read this object and call its intents.
public final class CompanionCoordinator: ObservableObject {
    // MARK: Published state
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var diagnostics = TelemetryDiagnostics()
    @Published public private(set) var aircraft: AircraftState?
    @Published public private(set) var phase: FlightPhase = .preflight
    @Published public private(set) var isActive = false
    @Published public private(set) var timeline: [TimelineEntry] = []
    @Published public private(set) var nowPlaying: [AudioChannel: AudioRequest] = [:]
    @Published public private(set) var lastAnnouncementText: String?
    @Published public private(set) var packs: [AirlinePack] = []
    @Published public private(set) var profiles: [AircraftProfile] = []
    @Published public private(set) var warnings: [String] = []
    @Published public private(set) var audioRoute = ""

    public var provider: SimulatorTelemetryProvider { currentProvider }
    public var mockProvider: MockTelemetryProvider? { currentProvider as? MockTelemetryProvider }
    public var capabilities: Set<TelemetryCapability> { currentProvider.capabilities }
    public var currentPack: AirlinePack? { library.pack(id: settings.airlineID) ?? library.packs.first }
    public var currentProfile: AircraftProfile? { profiles.first { $0.id == settings.aircraftProfileID } ?? profiles.first }
    public var eventMap: EventMap { announcements?.eventMap ?? EventMap(schemaVersion: 1, rules: []) }
    public var originElevationFeet: Double? { phaseEngine.originElevationFeet }

    // MARK: Dependencies
    private let locations: ResourceLocations
    private let library = AirlinePackLibrary()
    private let settingsStore: SettingsStore
    private let logStore: FlightLogStore?
    private let output: AudioOutput
    private let session: AudioSessionManager
    private let scheduler: AudioScheduler
    private let realClock: TimeSource
    private let providerFactory: (TelemetrySourceKind, AppSettings) -> SimulatorTelemetryProvider

    private var currentProvider: SimulatorTelemetryProvider
    private let phaseEngine: FlightPhaseEngine
    private var announcements: AnnouncementEngine?
    private var copilot: CopilotEngine?
    private var genericPack: AirlinePack?
    private var ambienceRequest: AudioRequest?
    private var providerBag = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>()
    private var lastUIUpdate: TimeInterval = 0
    private var flightRecord: FlightRecordSummary?
    private let maxTimeline = 300

    public init(locations: ResourceLocations,
                settingsStore: SettingsStore = SettingsStore(),
                logStore: FlightLogStore? = nil,
                output: AudioOutput,
                session: AudioSessionManager = AudioSessionManager(),
                realClock: TimeSource = SystemTimeSource(),
                providerFactory: @escaping (TelemetrySourceKind, AppSettings) -> SimulatorTelemetryProvider = CompanionCoordinator.defaultProvider) {
        self.locations = locations
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.output = output
        self.session = session
        self.realClock = realClock
        self.providerFactory = providerFactory
        let loaded = settingsStore.load()
        self.settings = loaded
        self.scheduler = AudioScheduler(output: output, timeSource: realClock)
        self.currentProvider = providerFactory(loaded.source, loaded)
        self.phaseEngine = FlightPhaseEngine(thresholds: loaded.thresholds, capabilities: currentProvider.capabilities)
        loadResources()
        rebuildEngines()
        applyAudioSettings()
        bindScheduler()
        bindSession()
        bindProvider()
    }

    public static func defaultProvider(_ kind: TelemetrySourceKind, _ settings: AppSettings) -> SimulatorTelemetryProvider {
        switch kind {
        case .aerofly:
            return AeroflyUDPProvider(port: settings.udpPort)
        case .demo:
            let m = MockTelemetryProvider(emulateBroadcastFields: settings.demoEmulatesBroadcastFields)
            m.timeScale = settings.demoTimeScale
            return m
        }
    }

    // MARK: - Intents: monitoring and companion

    /// Starts listening for telemetry; it doesn't start announcements. Call it on launch.
    public func startMonitoring() {
        configureMock()
        currentProvider.connect()
    }

    /// Makes the demo aircraft match the selected profile and destination.
    private func configureMock() {
        guard let mock = mockProvider else { return }
        var p = mock.script.parameters
        if let prof = currentProfile {
            p.rotateSpeedKnots = prof.speeds.vr + 1
            p.approachSpeedKnots = (prof.speeds.vref ?? 135) + 5
            mock.aircraftName = prof.name
        }
        if let dest = settings.flight.destinationElevationFeet { p.destinationElevationFeet = dest }
        if let cruise = settings.flight.cruiseAltitudeFeet { p.cruiseAltitudeFeet = cruise }
        mock.updateParameters(p)
    }

    public func reconnect() {
        currentProvider.disconnect()
        currentProvider.connect()
        log(.connection, "Reconnecting", detail: currentProvider.displayName)
    }

    public func startCompanion() {
        guard !isActive else { return }
        if !session.activate() {
            log(.warning, "Audio session unavailable", detail: session.lastError)
        }
        audioRoute = session.currentRouteDescription
        isActive = true
        phaseEngine.companionActive = true
        flightRecord = FlightRecordSummary(id: UUID(), startedAt: Date(), endedAt: nil,
                                           airline: currentPack?.manifest.name ?? "",
                                           aircraft: currentProfile?.name ?? "",
                                           source: currentProvider.displayName, entries: [])
        log(.event, "Companion started", detail: "\(currentPack?.manifest.name ?? "—") · \(currentProfile?.name ?? "—")")
        startAmbience()
        refreshWarnings()
    }

    public func stopCompanion() {
        guard isActive else { return }
        isActive = false
        phaseEngine.companionActive = false
        scheduler.clearAll()
        ambienceRequest = nil
        session.deactivate()
        log(.event, "Companion stopped")
        persistFlight(ended: true)
    }

    public func resetFlight() {
        let events = phaseEngine.reset()
        events.forEach(dispatch)
        copilot?.reset()
        announcements?.reset()
        scheduler.clear(.pa)
        scheduler.clear(.copilot)
        phase = phaseEngine.phase
        timeline.removeAll()
        if let mock = mockProvider { mock.restartFlight() }
        log(.event, "Flight reset")
    }

    public func forcePhase(_ p: FlightPhase) {
        let events = phaseEngine.forcePhase(p, at: currentProvider.currentAircraftState?.time)
        events.forEach(dispatch)
        phase = phaseEngine.phase
        releaseDueAnnouncements()
    }

    /// Plays any cue immediately (Audio settings previews, Demo triggers).
    public func preview(cue: String) {
        guard let engine = announcements else { return }
        if cue.hasPrefix("copilot."), let c = currentProfile?.callouts.first(where: { "copilot.\($0.id)" == cue }) {
            enqueueCallout(CopilotEngine.Fire(callout: c, time: 0, estimated: false), preview: true)
            return
        }
        switch engine.request(forCue: cue, now: currentProvider.currentAircraftState?.time ?? 0) {
        case .success(var req):
            if !session.activate() { log(.warning, "Audio session unavailable", detail: session.lastError) }
            req.loops = false
            scheduler.enqueue(req)
        case .failure(let f):
            log(.warning, "Can't preview", detail: f.description)
        }
    }

    public func stopPreview() { scheduler.clearAll(); if isActive { startAmbience() } }

    // MARK: - Intents: settings

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let old = settings
        settings = s
        settingsStore.save(s)
        if old.source != s.source || old.udpPort != s.udpPort || old.demoEmulatesBroadcastFields != s.demoEmulatesBroadcastFields {
            switchProvider()
        }
        if let mock = mockProvider {
            mock.timeScale = s.demoTimeScale
            if old.aircraftProfileID != s.aircraftProfileID && !isActive { configureMock() }
        }
        if old.airlineID != s.airlineID || old.language != s.language || old.aircraftProfileID != s.aircraftProfileID
            || old.flight != s.flight || old.speechFallback != s.speechFallback {
            rebuildEngines(preservingState: true)
            if old.airlineID != s.airlineID && isActive { startAmbience() }
        }
        applyEngineSettings()
        applyAudioSettings()
        if old.ambienceEnabled != s.ambienceEnabled && isActive {
            if s.ambienceEnabled { startAmbience() } else { scheduler.clear(.ambience, fade: 1.0); ambienceRequest = nil }
        }
        refreshWarnings()
    }

    public func reloadPacks() {
        loadResources()
        rebuildEngines(preservingState: true)
    }

    public func copilotAvailability() -> [(AircraftProfile.Callout, CopilotEngine.Availability)] {
        guard let c = copilot, let p = currentProfile else { return [] }
        return p.callouts.map { ($0, c.availability(of: $0)) }
    }

    public func recentFlights() -> [FlightRecordSummary] { logStore?.recent() ?? [] }

    // MARK: - Intents: app lifecycle

    public func sceneDidBecomeActive() {
        (currentProvider as? AeroflyUDPProvider)?.refreshAfterForeground()
        audioRoute = session.currentRouteDescription
    }

    public func sceneDidEnterBackground() {
        if isActive && ambienceRequest == nil {
            log(.warning, "Running in background without ambience",
                detail: "iOS may suspend AeroPA, which pauses telemetry. Turn on cabin ambience to keep it running.")
        }
        persistFlight(ended: false)
    }

    // MARK: - Wiring

    private func loadResources() {
        library.load(bundledPacksDirectory: locations.bundledAirlines,
                     userPacksDirectory: locations.userAirlines,
                     sharedDirectory: locations.shared)
        packs = library.packs
        library.loadErrors.forEach { log(.warning, "Pack error", detail: $0) }
        if let g = locations.genericPackURL { genericPack = try? AirlinePackLibrary.loadPack(at: g, userProvided: false) }
        if let url = locations.profilesURL {
            do { profiles = try AircraftProfileCatalog.load(from: url).profiles }
            catch { log(.warning, "Aircraft profiles failed to load", detail: "\(error)") }
        }
    }

    private func loadEventMap() -> EventMap {
        guard let url = locations.eventMapURL else { return EventMap(schemaVersion: 1, rules: []) }
        do { return try JSONDecoder().decode(EventMap.self, from: Data(contentsOf: url)) }
        catch {
            log(.warning, "Event map failed to load", detail: "\(error)")
            return EventMap(schemaVersion: 1, rules: [])
        }
    }

    private func rebuildEngines(preservingState: Bool = false) {
        if let pack = currentPack {
            let language = pack.manifest.languages.contains(settings.language) ? settings.language : pack.manifest.defaultLanguage
            let resolver = CueResolver(pack: pack, language: language, sharedScripts: library.sharedScripts,
                                       context: settings.announcementContext(airlineName: pack.manifest.placeholders?["airline"] ?? pack.manifest.name),
                                       allowSpeechFallback: settings.speechFallback, fallbackPack: genericPack)
            if let existing = announcements, preservingState {
                existing.resolver = resolver
            } else {
                announcements = AnnouncementEngine(eventMap: loadEventMap(), resolver: resolver)
            }
        } else {
            announcements = nil
            log(.warning, "No airline packs installed")
        }
        if let profile = currentProfile {
            if let c = copilot { if c.profile.id != profile.id { c.profile = profile } }
            else { copilot = CopilotEngine(profile: profile, settings: settings.copilot, capabilities: capabilities) }
        }
        applyEngineSettings()
    }

    private func applyEngineSettings() {
        phaseEngine.thresholds = settings.thresholds
        phaseEngine.mode = settings.phaseDetection
        phaseEngine.capabilities = capabilities
        phaseEngine.destinationElevationFeet = settings.flight.destinationElevationFeet
        announcements?.enabled = settings.announcementsEnabled
        announcements?.disabledCategories = settings.disabledCategories
        announcements?.ruleOverrides = settings.ruleOverrides
        copilot?.settings = settings.copilot
        copilot?.capabilities = capabilities
        copilot?.approachHeightAvailable = settings.flight.destinationElevationFeet != nil || capabilities.contains(.radioAltitude)
    }

    private func applyAudioSettings() {
        for ch in AudioChannel.allCases { output.setVolume(settings.volume(ch), for: ch) }
        if let av = output as? AVAudioOutput {
            var e = av.effects
            e.paSpeakerEffect = settings.paSpeakerEffect
            e.copilotInterphoneEffect = settings.copilotInterphoneEffect
            av.effects = e
        }
    }

    private func switchProvider() {
        providerBag.removeAll()
        currentProvider.disconnect()
        currentProvider = providerFactory(settings.source, settings)
        aircraft = nil
        diagnostics = TelemetryDiagnostics()
        _ = phaseEngine.reset()
        copilot?.reset()
        announcements?.reset()
        phase = .preflight
        applyEngineSettings()
        bindProvider()
        configureMock()
        currentProvider.connect()
        log(.connection, "Source: \(currentProvider.displayName)")
    }

    private func bindProvider() {
        currentProvider.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let old = self.connectionState
                self.connectionState = state
                if old.title != state.title { self.log(.connection, state.title, detail: self.connectionDetail(state)) }
                self.refreshWarnings()
            }
            .store(in: &providerBag)
        currentProvider.diagnosticsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in self?.diagnostics = d }
            .store(in: &providerBag)
        currentProvider.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.handleTelemetry(s) }
            .store(in: &providerBag)
    }

    private func connectionDetail(_ state: ConnectionState) -> String? {
        switch state {
        case .listening(let port): return "UDP \(port)"
        case .failed(let e): return e.description
        case .stale(let s): return "No packets for \(Int(s)) s"
        default: return nil
        }
    }

    private func bindScheduler() {
        scheduler.outcomes
            .sink { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .started(let r):
                    self.nowPlaying[r.channel] = r
                case .finished(let r), .interrupted(let r):
                    if self.nowPlaying[r.channel]?.id == r.id { self.nowPlaying[r.channel] = nil }
                case .expired(let r):
                    self.log(.warning, "Skipped late audio", detail: r.title)
                case .failed(let r, let e):
                    if self.nowPlaying[r.channel]?.id == r.id { self.nowPlaying[r.channel] = nil }
                    self.log(.warning, "Playback failed", detail: "\(r.title): \(e.description)")
                }
            }
            .store(in: &bag)
    }

    private func bindSession() {
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .interruptionBegan:
                self.scheduler.suspend()
                self.log(.warning, "Audio interrupted")
            case .interruptionEnded(let resume):
                if resume || self.isActive {
                    _ = self.session.activate()
                    (self.output as? AVAudioOutput)?.startEngineIfNeeded()
                    self.scheduler.resume(restartLoops: self.ambienceRequest.map { [$0] } ?? [])
                    self.log(.event, "Audio resumed")
                }
            case .routeChanged(let route):
                self.audioRoute = route
            case .mediaServicesReset:
                self.log(.warning, "Audio services were reset")
                if self.isActive { self.startAmbience() }
            }
        }
    }

    // MARK: - Telemetry pipeline

    private func handleTelemetry(_ s: AircraftState) {
        let now = realClock.now
        if now - lastUIUpdate > 0.2 {
            aircraft = s
            lastUIUpdate = now
        }
        guard isActive else { return }
        let events = phaseEngine.process(s)
        events.forEach(dispatch)
        if phase != phaseEngine.phase { phase = phaseEngine.phase }

        if let cp = copilot {
            let height = phaseEngine.estimatedHeightAboveGround(s).map { HeightEstimate(feet: $0.feet, reliable: $0.reliable) }
            for fire in cp.process(s, phase: phaseEngine.phase, height: height) { enqueueCallout(fire, preview: false) }
        }
        releaseDueAnnouncements()
    }

    private func dispatch(_ event: FlightEvent) {
        switch event.kind {
        case .phaseChanged(_, let to):
            log(.phase, to.displayName)
            if to == .flightEnded { persistFlight(ended: true) }
        case .flightReset:
            break
        default:
            log(.event, event.kind.description)
        }
        for report in announcements?.handle(event) ?? [] {
            if case .skippedDuplicate(let id) = report { log(.event, "Duplicate suppressed", detail: id) }
        }
        _ = copilot?.handle(event)
    }

    private func releaseDueAnnouncements() {
        guard let engine = announcements else { return }
        let now = currentProvider.currentAircraftState?.time ?? 0
        let (requests, reports) = engine.tick(now: now, phase: phaseEngine.phase)
        for r in reports {
            switch r {
            case .emitted(let req, let text, let synth):
                log(req.channel == .pa ? .announcement : .sound, req.title,
                    detail: synth ? "Synthesized voice" + (text.map { " · \($0)" } ?? "") : text)
                if req.channel == .pa, let text { lastAnnouncementText = text }
            case .unresolved(let id, let reason):
                log(.warning, "Missing audio", detail: "\(id): \(reason)")
            case .cancelled(let id, let reason):
                log(.event, "Cancelled \(id)", detail: reason)
            default: break
            }
        }
        requests.forEach(scheduler.enqueue)
    }

    private func enqueueCallout(_ fire: CopilotEngine.Fire, preview: Bool) {
        let cue = "copilot.\(fire.callout.id)"
        var source: AudioSource?
        if let pack = currentPack {
            let resolver = CueResolver(pack: pack, language: settings.language, sharedScripts: [:],
                                       context: AnnouncementContext(), allowSpeechFallback: false, fallbackPack: genericPack)
            if case .success(let src) = resolver.resolveFileOnly(cue) { source = src }
        }
        if source == nil && settings.speechFallback {
            source = .speech(text: fire.callout.text, voiceLanguage: "en-US")
        }
        guard let src = source else {
            log(.warning, "Missing callout audio", detail: fire.callout.text)
            return
        }
        // Speed callouts are useless late; height callouts slightly less so.
        let latency: TimeInterval = fire.callout.trigger.type == .airspeedIncreasing ? 1.5 : 3
        let req = AudioRequest(cueKey: cue, title: fire.callout.text, channel: .copilot, priority: 90,
                               source: src, maxLatency: preview ? 10 : latency, interruptible: false)
        if preview { _ = session.activate() }
        scheduler.enqueue(req)
        if !preview { log(.callout, fire.callout.text, detail: fire.estimated ? "Estimated" : nil) }
    }

    private func startAmbience() {
        guard settings.ambienceEnabled, let engine = announcements else { return }
        switch engine.request(forCue: "ambience.cabin", now: 0) {
        case .success(var req):
            req.loops = true
            req.maxLatency = nil
            ambienceRequest = req
            scheduler.clear(.ambience, fade: 0)
            scheduler.enqueue(req)
        case .failure(let f):
            log(.warning, "Ambience unavailable", detail: f.description)
        }
    }

    private func refreshWarnings() {
        var w: [String] = []
        if case .failed(let e) = connectionState { w.append(e.description) }
        if isActive && !settings.ambienceEnabled {
            w.append("Cabin ambience is off. iOS may suspend AeroPA in the background, which stops telemetry.")
        }
        if isActive && settings.volume(.ambience) < 0.05 && settings.ambienceEnabled {
            w.append("Ambience volume is near zero. Background operation relies on audible playback.")
        }
        if !capabilities.contains(.indicatedAirspeed) && settings.copilot.allowGroundSpeedAsAirspeed {
            w.append("Speed callouts use ground speed: Aerofly's broadcast has no airspeed.")
        }
        warnings = w
    }

    // MARK: - Timeline / persistence

    private func log(_ kind: TimelineEntry.Kind, _ title: String, detail: String? = nil) {
        let entry = TimelineEntry(kind: kind, title: title, detail: detail)
        timeline.append(entry)
        if timeline.count > maxTimeline { timeline.removeFirst(timeline.count - maxTimeline) }
        flightRecord?.entries.append(entry)
    }

    private func persistFlight(ended: Bool) {
        guard var record = flightRecord, let store = logStore else { return }
        if ended { record.endedAt = Date() }
        store.save(record)
        if ended { flightRecord = nil } else { flightRecord = record }
    }
}
