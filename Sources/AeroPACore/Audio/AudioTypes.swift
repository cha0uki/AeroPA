import Foundation

/// Independently mixed output channels.
public enum AudioChannel: String, Codable, CaseIterable, Sendable, Hashable {
    /// Passenger announcements.
    case pa
    /// First-officer callouts.
    case copilot
    /// Looping cabin ambience.
    case ambience
    /// Chimes and one-shot cabin sound effects.
    case sfx

    public var displayName: String {
        switch self {
        case .pa: return "Announcements"
        case .copilot: return "First officer"
        case .ambience: return "Cabin ambience"
        case .sfx: return "Sound effects"
        }
    }
}

/// What to play.
public enum AudioSource: Equatable, Sendable {
    case file(URL)
    /// Synthesised speech, used when the pack has no recording for a cue.
    /// The UI labels it as a synthesised voice, never as an airline recording.
    case speech(text: String, voiceLanguage: String)
}

public struct AudioRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var cueKey: String
    public var title: String
    public var channel: AudioChannel
    /// 0–100. Higher plays first and may interrupt lower priorities.
    public var priority: Int
    public var source: AudioSource
    /// Optional sound played on the SFX channel just before the item (e.g. the PA chime).
    public var leadIn: AudioSource?
    /// Seconds after enqueueing before the item is stale and dropped unplayed.
    /// Copilot callouts use very short values ("V1" said late is worse than not at all).
    /// The scheduler turns this into a deadline on its own clock.
    public var maxLatency: TimeInterval?
    public var interruptible: Bool
    public var loops: Bool

    public init(id: UUID = UUID(), cueKey: String, title: String, channel: AudioChannel, priority: Int,
                source: AudioSource, leadIn: AudioSource? = nil, maxLatency: TimeInterval? = nil,
                interruptible: Bool = true, loops: Bool = false) {
        self.id = id
        self.cueKey = cueKey
        self.title = title
        self.channel = channel
        self.priority = priority
        self.source = source
        self.leadIn = leadIn
        self.maxLatency = maxLatency
        self.interruptible = interruptible
        self.loops = loops
    }
}

public enum AudioPlaybackError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileMissing(String)
    case decodeFailed(String)
    case engineUnavailable(String)
    case speechUnavailable

    public var description: String {
        switch self {
        case .fileMissing(let f): return "Audio file missing: \(f)"
        case .decodeFailed(let f): return "Couldn't decode \(f)"
        case .engineUnavailable(let m): return "Audio engine unavailable: \(m)"
        case .speechUnavailable: return "Speech synthesis unavailable"
        }
    }
}

/// Abstract sink. `AVAudioOutput` is the real implementation; tests use a recorder.
/// All calls happen on the main queue, and completions must be delivered on main too.
public protocol AudioOutput: AnyObject {
    func play(_ source: AudioSource, on channel: AudioChannel, loops: Bool,
              completion: @escaping (Result<Void, AudioPlaybackError>) -> Void)
    func stop(channel: AudioChannel, fadeDuration: TimeInterval)
    func setVolume(_ volume: Float, for channel: AudioChannel)
    /// Temporarily lowers a channel (multiplier 0–1) with a fade.
    func setDuck(_ multiplier: Float, for channel: AudioChannel, fadeDuration: TimeInterval)
    func stopAll()
}
