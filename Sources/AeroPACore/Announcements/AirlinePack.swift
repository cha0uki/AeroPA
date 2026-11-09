import Foundation

/// `manifest.json` of an airline audio pack. Filenames live here only;
/// the event engine refers to cue keys such as `pa.welcome`.
///
/// Pack contents must be original recordings, licensed recordings, or audio
/// the user provides. AeroPA ships no airline recordings and makes no claim
/// that any audio is authentic airline audio.
public struct AirlinePackManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    /// Two-letter code, used for the monogram artwork.
    public var shortCode: String
    public var brandColorHex: String?
    /// Optional artwork image (relative path) that the pack owner supplies under licence.
    public var artwork: String?
    public var languages: [String]
    public var defaultLanguage: String
    /// BCP-47 voice per language for synthesised fallback, e.g. "fr" → "fr-FR".
    public var speechVoices: [String: String]?
    /// Values for `{placeholder}` substitution, e.g. "airline" → "Air France".
    public var placeholders: [String: String]?
    /// When true, cues without their own variants fall back to the shared scripts.
    public var inheritSharedScripts: Bool?
    public var cues: [String: CueDefinition]?
    public var credits: String?
    public var disclaimer: String?

    public struct CueDefinition: Codable, Equatable, Sendable {
        public var channel: AudioChannel?
        public var priority: Int?
        /// Cue key of a lead-in sound, e.g. "sfx.chime".
        public var leadIn: String?
        public var loops: Bool?
        public var variants: [Variant]
    }

    public struct Variant: Codable, Equatable, Sendable {
        public var language: String?
        /// Path relative to the pack folder.
        public var file: String?
        /// Script text, used for synthesised fallback and shown in the timeline.
        public var text: String?
        public var weight: Double?
    }
}

/// Shared scripts per language (Resources/Shared/scripts.<lang>.json), keyed by cue.
public struct SharedScripts: Codable, Equatable, Sendable {
    public var language: String
    public var cues: [String: [String]]
}

/// A loaded pack: its manifest plus where its files are.
public struct AirlinePack: Identifiable, Equatable, Sendable {
    public var manifest: AirlinePackManifest
    public var baseURL: URL
    public var isUserProvided: Bool
    public var id: String { manifest.id }

    public init(manifest: AirlinePackManifest, baseURL: URL, isUserProvided: Bool) {
        self.manifest = manifest
        self.baseURL = baseURL
        self.isUserProvided = isUserProvided
    }

    public func url(for relativePath: String) -> URL {
        baseURL.appendingPathComponent(relativePath)
    }

    /// Variants with a file that actually exists on disk.
    public func installedAudioFileCount(fileManager: FileManager = .default) -> Int {
        (manifest.cues ?? [:]).values.reduce(0) { sum, cue in
            sum + cue.variants.filter { v in
                guard let f = v.file else { return false }
                return fileManager.fileExists(atPath: url(for: f).path)
            }.count
        }
    }

    public func missingAudioFiles(fileManager: FileManager = .default) -> [String] {
        (manifest.cues ?? [:]).values.flatMap { cue in
            cue.variants.compactMap { v -> String? in
                guard let f = v.file, !fileManager.fileExists(atPath: url(for: f).path) else { return nil }
                return f
            }
        }.sorted()
    }
}

public enum AirlinePackError: Error, Equatable, CustomStringConvertible {
    case manifestMissing(String)
    case manifestInvalid(String, String)
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .manifestMissing(let p): return "No manifest.json in \(p)"
        case .manifestInvalid(let p, let e): return "Invalid manifest in \(p): \(e)"
        case .unsupportedSchema(let v): return "Unsupported manifest schema \(v)"
        }
    }
}

/// Discovers packs in the app bundle and in the user's Documents/AirlinePacks folder.
public final class AirlinePackLibrary {
    public static let supportedSchema = 1
    public private(set) var packs: [AirlinePack] = []
    public private(set) var loadErrors: [String] = []
    public private(set) var sharedScripts: [String: SharedScripts] = [:]

    public init() {}

    public func load(bundledPacksDirectory: URL?, userPacksDirectory: URL?, sharedDirectory: URL?) {
        packs = []
        loadErrors = []
        if let shared = sharedDirectory { loadSharedScripts(from: shared) }
        if let dir = bundledPacksDirectory { loadPacks(in: dir, userProvided: false) }
        if let dir = userPacksDirectory { loadPacks(in: dir, userProvided: true) }
        // A user pack with the same id replaces the bundled one.
        var byID: [String: AirlinePack] = [:]
        for p in packs { if byID[p.id] == nil || p.isUserProvided { byID[p.id] = p } }
        packs = byID.values.sorted { $0.manifest.name < $1.manifest.name }
    }

    public func pack(id: String) -> AirlinePack? { packs.first { $0.id == id } }

    public static func loadPack(at folder: URL, userProvided: Bool) throws -> AirlinePack {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw AirlinePackError.manifestMissing(folder.lastPathComponent)
        }
        do {
            let m = try JSONDecoder().decode(AirlinePackManifest.self, from: data)
            guard m.schemaVersion == supportedSchema else { throw AirlinePackError.unsupportedSchema(m.schemaVersion) }
            return AirlinePack(manifest: m, baseURL: folder, isUserProvided: userProvided)
        } catch let e as AirlinePackError {
            throw e
        } catch {
            throw AirlinePackError.manifestInvalid(folder.lastPathComponent, "\(error)")
        }
    }

    private func loadPacks(in directory: URL, userProvided: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for folder in entries where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do { packs.append(try Self.loadPack(at: folder, userProvided: userProvided)) }
            catch { loadErrors.append("\(error)") }
        }
    }

    private func loadSharedScripts(from directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("scripts.") && f.pathExtension == "json" {
            do {
                let s = try JSONDecoder().decode(SharedScripts.self, from: Data(contentsOf: f))
                sharedScripts[s.language] = s
            } catch {
                loadErrors.append("Invalid shared script \(f.lastPathComponent): \(error)")
            }
        }
    }
}
