import Foundation
import XCTest
@testable import AeroPACore

final class AnnouncementEngineTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aeropa-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir.appendingPathComponent("PA"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func makePack(cues: [String: AirlinePackManifest.CueDefinition], languages: [String] = ["en", "fr"]) -> AirlinePack {
        let m = AirlinePackManifest(schemaVersion: 1, id: "test", name: "Test Air", shortCode: "TA", brandColorHex: nil,
                                    artwork: nil, languages: languages, defaultLanguage: "en", speechVoices: ["fr": "fr-FR"],
                                    placeholders: ["airline": "Test Air"], inheritSharedScripts: true, cues: cues,
                                    credits: nil, disclaimer: nil)
        return AirlinePack(manifest: m, baseURL: tempDir, isUserProvided: true)
    }

    func touch(_ rel: String) {
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent(rel).path, contents: Data([0]))
    }

    func engine(rules: [EventMap.Rule], pack: AirlinePack, language: String = "en", speech: Bool = true,
                shared: [String: SharedScripts] = [:], context: AnnouncementContext = .init()) -> AnnouncementEngine {
        let resolver = CueResolver(pack: pack, language: language, sharedScripts: shared, context: context, allowSpeechFallback: speech)
        return AnnouncementEngine(eventMap: EventMap(schemaVersion: 1, rules: rules), resolver: resolver, rng: SeededRNG(seed: 42))
    }

    func rule(_ id: String, on: String, cue: String, delay: TimeInterval = 0, valid: [FlightPhase]? = nil,
              repeatable: Bool = false, cooldown: TimeInterval? = nil, category: AnnouncementCategory = .crew) -> EventMap.Rule {
        EventMap.Rule(id: id, on: on, cue: cue, delay: delay, validPhases: valid, priority: nil, cooldown: cooldown,
                      repeatable: repeatable, category: category, enabledByDefault: nil, maxLatency: nil)
    }

    func phaseEvent(_ p: FlightPhase, at t: TimeInterval) -> FlightEvent {
        FlightEvent(kind: .phaseChanged(from: .preflight, to: p), time: t, phase: p)
    }

    func testSchedulesWithDelayAndPlaysRecordedFile() {
        touch("PA/cruise_en.m4a")
        let pack = makePack(cues: ["pa.cruise": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil,
                                                      variants: [.init(language: "en", file: "PA/cruise_en.m4a", text: nil, weight: nil)])])
        let e = engine(rules: [rule("cruise", on: "phase.CRUISE", cue: "pa.cruise", delay: 60)], pack: pack)
        _ = e.handle(phaseEvent(.cruise, at: 100))
        XCTAssertTrue(e.tick(now: 159, phase: .cruise).requests.isEmpty)
        let out = e.tick(now: 160, phase: .cruise).requests
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, .file(tempDir.appendingPathComponent("PA/cruise_en.m4a")))
    }

    func testDeduplicatesWithinAFlight() {
        let pack = makePack(cues: ["pa.x": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil, variants: [.init(language: nil, file: nil, text: "Hello", weight: nil)])])
        let e = engine(rules: [rule("x", on: "phase.CRUISE", cue: "pa.x")], pack: pack)
        _ = e.handle(phaseEvent(.cruise, at: 0))
        XCTAssertEqual(e.tick(now: 0, phase: .cruise).requests.count, 1)
        let reports = e.handle(phaseEvent(.cruise, at: 10))
        XCTAssertEqual(reports, [.skippedDuplicate(ruleID: "x")])
        XCTAssertTrue(e.tick(now: 10, phase: .cruise).requests.isEmpty)
    }

    func testRepeatableRuleHonoursCooldown() {
        let pack = makePack(cues: ["pa.x": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil, variants: [.init(language: nil, file: nil, text: "Hi", weight: nil)])])
        let e = engine(rules: [rule("x", on: "event.goAround", cue: "pa.x", repeatable: true, cooldown: 120)], pack: pack)
        _ = e.handle(FlightEvent(kind: .goAround, time: 0, phase: .climb))
        XCTAssertEqual(e.tick(now: 0, phase: .climb).requests.count, 1)
        _ = e.handle(FlightEvent(kind: .goAround, time: 30, phase: .climb))
        let r = e.tick(now: 30, phase: .climb)
        XCTAssertTrue(r.requests.isEmpty)
        XCTAssertEqual(r.reports, [.skippedCooldown(ruleID: "x")])
        _ = e.handle(FlightEvent(kind: .goAround, time: 200, phase: .climb))
        XCTAssertEqual(e.tick(now: 200, phase: .climb).requests.count, 1)
    }

    func testCancelledWhenPhaseNoLongerValid() {
        let pack = makePack(cues: ["pa.service": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil, variants: [.init(language: nil, file: nil, text: "Meal", weight: nil)])])
        let e = engine(rules: [rule("meal", on: "phase.CRUISE", cue: "pa.service", delay: 300, valid: [.cruise])], pack: pack)
        _ = e.handle(phaseEvent(.cruise, at: 0))
        let r = e.tick(now: 301, phase: .descent)
        XCTAssertTrue(r.requests.isEmpty)
        XCTAssertEqual(r.reports.count, 1)
        if case .cancelled(let id, _) = r.reports[0] { XCTAssertEqual(id, "meal") } else { XCTFail() }
    }

    func testDisabledCategoryAndOverride() {
        let pack = makePack(cues: [:])
        let e = engine(rules: [rule("safety", on: "phase.TAXI", cue: "pa.safety", category: .safety)], pack: pack)
        e.disabledCategories = [.safety]
        XCTAssertEqual(e.handle(phaseEvent(.taxi, at: 0)), [.skippedDisabled(ruleID: "safety")])
        e.ruleOverrides["safety"] = true
        XCTAssertEqual(e.handle(phaseEvent(.taxi, at: 1)), [.scheduled(ruleID: "safety", dueAt: 1)])
    }

    func testMissingFileFallsBackToSpeechInSelectedLanguage() {
        let pack = makePack(cues: ["pa.welcome": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil,
                                                       variants: [.init(language: "fr", file: "PA/welcome_fr.m4a", text: nil, weight: nil)])])
        let shared = ["fr": SharedScripts(language: "fr", cues: ["pa.welcome": ["Bienvenue à bord de {airline}."]])]
        let e = engine(rules: [rule("w", on: "phase.BOARDING", cue: "pa.welcome")], pack: pack, language: "fr", shared: shared,
                       context: AnnouncementContext(values: ["airline": "Test Air"]))
        _ = e.handle(phaseEvent(.boarding, at: 0))
        let r = e.tick(now: 0, phase: .boarding)
        XCTAssertEqual(r.requests.first?.source, .speech(text: "Bienvenue à bord de Test Air.", voiceLanguage: "fr-FR"))
        if case .emitted(_, _, let synth) = r.reports[0] { XCTAssertTrue(synth, "Must be flagged as synthesised") } else { XCTFail() }
    }

    func testMissingFileWithoutFallbackIsReportedNotPlayed() {
        let pack = makePack(cues: ["pa.welcome": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil,
                                                       variants: [.init(language: "en", file: "PA/missing.m4a", text: nil, weight: nil)])])
        let e = engine(rules: [rule("w", on: "phase.BOARDING", cue: "pa.welcome")], pack: pack, speech: false)
        _ = e.handle(phaseEvent(.boarding, at: 0))
        let r = e.tick(now: 0, phase: .boarding)
        XCTAssertTrue(r.requests.isEmpty)
        if case .unresolved(_, let reason) = r.reports[0] { XCTAssertTrue(reason.contains("missing.m4a")) } else { XCTFail("\(r.reports)") }
    }

    func testResetAllowsAnnouncementsAgain() {
        let pack = makePack(cues: ["pa.x": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil, variants: [.init(language: nil, file: nil, text: "Hi", weight: nil)])])
        let e = engine(rules: [rule("x", on: "phase.CRUISE", cue: "pa.x", delay: 50)], pack: pack)
        _ = e.handle(phaseEvent(.cruise, at: 0))
        _ = e.handle(FlightEvent(kind: .flightReset, time: 1, phase: .preflight))
        XCTAssertTrue(e.pending.isEmpty, "Reset cancels pending announcements")
        _ = e.handle(phaseEvent(.cruise, at: 2))
        XCTAssertEqual(e.pending.count, 1)
    }

    func testRandomVariantSelectionIsWeightedAndDeterministicWithSeed() {
        touch("PA/a.m4a"); touch("PA/b.m4a")
        let pack = makePack(cues: ["pa.x": .init(channel: .pa, priority: nil, leadIn: nil, loops: nil, variants: [
            .init(language: nil, file: "PA/a.m4a", text: nil, weight: 1),
            .init(language: nil, file: "PA/b.m4a", text: nil, weight: 0)])])
        let resolver = CueResolver(pack: pack, language: "en", sharedScripts: [:], context: .init(), allowSpeechFallback: false)
        var rng = SeededRNG(seed: 7)
        for _ in 0..<20 {
            guard case .success(let r) = resolver.resolve("pa.x", using: &rng) else { return XCTFail() }
            XCTAssertEqual(r.source, .file(tempDir.appendingPathComponent("PA/a.m4a")))
        }
    }

    func testPlaceholderRenderingDropsUnknownOptionalSegments() {
        let ctx = AnnouncementContext(values: ["airline": "Air X", "destination": "Paris"])
        XCTAssertEqual(ctx.render("Welcome to {airline}[ flight {flightNumber}][ to {destination}]."), "Welcome to Air X to Paris.")
        XCTAssertEqual(ctx.render("Captain {captain} speaking."), "Captain speaking.")
    }
}

final class AirlinePackLibraryTests: XCTestCase {
    func testAllBundledPacksLoad() {
        let lib = AirlinePackLibrary()
        lib.load(bundledPacksDirectory: TestPaths.airlines, userPacksDirectory: nil, sharedDirectory: TestPaths.shared)
        XCTAssertTrue(lib.loadErrors.isEmpty, "\(lib.loadErrors)")
        let ids = Set(lib.packs.map(\.id))
        XCTAssertEqual(ids, ["air-france", "royal-air-maroc", "emirates", "qatar-airways", "lufthansa", "british-airways", "turkish-airlines"])
        for p in lib.packs {
            XCTAssertTrue(p.manifest.languages.contains(p.manifest.defaultLanguage), p.id)
            XCTAssertNotNil(p.manifest.disclaimer, "Packs must carry the non-affiliation disclaimer")
        }
    }

    func testEverySharedScriptLanguageCoversEveryPACueInEventMap() throws {
        let map = try loadEventMap()
        let lib = AirlinePackLibrary()
        lib.load(bundledPacksDirectory: TestPaths.airlines, userPacksDirectory: nil, sharedDirectory: TestPaths.shared)
        let paCues = Set(map.rules.map(\.cue).filter { $0.hasPrefix("pa.") })
        for pack in lib.packs {
            for lang in pack.manifest.languages {
                let script = try XCTUnwrap(lib.sharedScripts[lang], "No shared script for \(lang)")
                XCTAssertTrue(paCues.isSubset(of: Set(script.cues.keys)), "\(lang) misses \(paCues.subtracting(script.cues.keys))")
            }
        }
    }

    func testGenericPackSoundsExistAndAirlineFallsBackToThem() throws {
        let generic = try AirlinePackLibrary.loadPack(at: TestPaths.shared.appendingPathComponent("GenericPack"), userProvided: false)
        XCTAssertTrue(generic.missingAudioFiles().isEmpty, "\(generic.missingAudioFiles())")
        let af = try AirlinePackLibrary.loadPack(at: TestPaths.airlines.appendingPathComponent("air-france"), userProvided: false)
        let resolver = CueResolver(pack: af, language: "fr", sharedScripts: [:], context: .init(), allowSpeechFallback: false, fallbackPack: generic)
        guard case .success(.file(let url)) = resolver.resolveFileOnly("sfx.chime") else { return XCTFail() }
        XCTAssertTrue(url.path.contains("GenericPack"))
    }

    func testUserPackOverridesBundledPack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("userpacks-\(UUID().uuidString)")
        let folder = tmp.appendingPathComponent("air-france")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestPaths.airlines.appendingPathComponent("air-france/manifest.json"),
                                         to: folder.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AirlinePackLibrary()
        lib.load(bundledPacksDirectory: TestPaths.airlines, userPacksDirectory: tmp, sharedDirectory: nil)
        XCTAssertEqual(lib.pack(id: "air-france")?.isUserProvided, true)
        XCTAssertEqual(lib.packs.filter { $0.id == "air-france" }.count, 1)
    }

    func testInvalidManifestIsReportedNotFatal() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("badpack-\(UUID().uuidString)")
        let folder = tmp.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AirlinePackLibrary()
        lib.load(bundledPacksDirectory: tmp, userPacksDirectory: nil, sharedDirectory: nil)
        XCTAssertTrue(lib.packs.isEmpty)
        XCTAssertEqual(lib.loadErrors.count, 1)
    }
}
