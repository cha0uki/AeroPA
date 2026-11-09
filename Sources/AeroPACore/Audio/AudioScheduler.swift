import Foundation
import Combine

/// Per-channel priority queues on top of an `AudioOutput`.
///
/// Rules:
/// * Each channel plays one item at a time; waiting items are ordered by priority, then FIFO.
/// * A new item interrupts the current one only if the current item is interruptible
///   and the new priority is at least `interruptMargin` higher.
/// * Expired items are dropped at dequeue time and reported.
/// * Ambience ducks while PA or copilot audio is playing. PA ducks under copilot
///   if `duckPAForCopilot` is set.
/// * A lead-in (chime) plays on the SFX channel, then the main item starts.
public final class AudioScheduler {
    public enum Outcome: Equatable, Sendable {
        case started(AudioRequest)
        case finished(AudioRequest)
        case interrupted(AudioRequest)
        case expired(AudioRequest)
        case failed(AudioRequest, AudioPlaybackError)
    }

    public var interruptMargin = 20
    public var ambienceDuckLevel: Float = 0.35
    public var duckPAForCopilot = true
    public var paDuckLevelForCopilot: Float = 0.5

    private let output: AudioOutput
    private let timeSource: TimeSource
    private var current: [AudioChannel: AudioRequest] = [:]
    private var queues: [AudioChannel: [(seq: Int, req: AudioRequest)]] = [:]
    private var seq = 0
    /// Bumped on every start so stale completions from stopped items are ignored.
    private var generation: [AudioChannel: Int] = [:]
    private var awaitingLeadIn: Set<AudioChannel> = []
    private var suspended = false
    private var deadlines: [UUID: TimeInterval] = [:]

    private let outcomeSubject = PassthroughSubject<Outcome, Never>()
    public var outcomes: AnyPublisher<Outcome, Never> { outcomeSubject.eraseToAnyPublisher() }

    public init(output: AudioOutput, timeSource: TimeSource = SystemTimeSource()) {
        self.output = output
        self.timeSource = timeSource
    }

    public func nowPlaying(_ channel: AudioChannel) -> AudioRequest? { current[channel] }
    public func queued(_ channel: AudioChannel) -> [AudioRequest] { (queues[channel] ?? []).map(\.req) }

    public func enqueue(_ request: AudioRequest) {
        if let latency = request.maxLatency { deadlines[request.id] = timeSource.now + latency }
        let ch = request.channel
        if let playing = current[ch] {
            if playing.interruptible && request.priority >= playing.priority + interruptMargin {
                interruptCurrent(on: ch)
                start(request)
            } else {
                insert(request)
            }
        } else if suspended {
            insert(request)
        } else {
            start(request)
        }
    }

    /// Stops a channel and clears its queue.
    public func clear(_ channel: AudioChannel, fade: TimeInterval = 0.3) {
        queues[channel] = []
        if current[channel] != nil {
            interruptCurrent(on: channel, fade: fade)
        }
        updateDucking()
    }

    public func clearAll() {
        for ch in AudioChannel.allCases { clear(ch, fade: 0.2) }
    }

    /// Called on an audio-session interruption (phone call, Siri). Items stay queued;
    /// non-looping items in progress are dropped, because resuming a half-said PA sounds wrong.
    public func suspend() {
        suspended = true
        for (ch, req) in current where !req.loops {
            generation[ch, default: 0] += 1
            current[ch] = nil
            outcomeSubject.send(.interrupted(req))
        }
    }

    /// Resumes after an interruption, restarting looped ambience and draining queues.
    public func resume(restartLoops: [AudioRequest] = []) {
        suspended = false
        for loop in restartLoops where current[loop.channel] == nil { start(loop) }
        for ch in AudioChannel.allCases where current[ch] == nil { startNext(on: ch) }
    }

    // MARK: - Internals

    private func insert(_ request: AudioRequest) {
        seq += 1
        var q = queues[request.channel] ?? []
        q.append((seq, request))
        q.sort { a, b in a.req.priority != b.req.priority ? a.req.priority > b.req.priority : a.seq < b.seq }
        queues[request.channel] = q
    }

    private func interruptCurrent(on ch: AudioChannel, fade: TimeInterval = 0.25) {
        guard let playing = current[ch] else { return }
        generation[ch, default: 0] += 1
        current[ch] = nil
        awaitingLeadIn.remove(ch)
        output.stop(channel: ch, fadeDuration: fade)
        outcomeSubject.send(.interrupted(playing))
    }

    private func start(_ request: AudioRequest) {
        if let deadline = deadlines.removeValue(forKey: request.id), timeSource.now > deadline {
            outcomeSubject.send(.expired(request))
            startNext(on: request.channel)
            return
        }
        let ch = request.channel
        generation[ch, default: 0] += 1
        let gen = generation[ch] ?? 0
        current[ch] = request
        updateDucking()
        outcomeSubject.send(.started(request))

        let playMain = { [weak self] in
            guard let self, self.generation[ch] == gen else { return }
            self.awaitingLeadIn.remove(ch)
            self.output.play(request.source, on: ch, loops: request.loops) { [weak self] result in
                self?.didFinish(request, generation: gen, result: result)
            }
        }
        if let leadIn = request.leadIn, ch != .sfx {
            awaitingLeadIn.insert(ch)
            output.play(leadIn, on: .sfx, loops: false) { _ in
                // A missing chime must never block the announcement.
                playMain()
            }
        } else {
            playMain()
        }
    }

    private func didFinish(_ request: AudioRequest, generation gen: Int, result: Result<Void, AudioPlaybackError>) {
        let ch = request.channel
        guard generation[ch] == gen, current[ch]?.id == request.id else { return }
        current[ch] = nil
        switch result {
        case .success: outcomeSubject.send(.finished(request))
        case .failure(let e): outcomeSubject.send(.failed(request, e))
        }
        updateDucking()
        if !suspended { startNext(on: ch) }
    }

    private func startNext(on ch: AudioChannel) {
        guard current[ch] == nil, var q = queues[ch], !q.isEmpty else { updateDucking(); return }
        let next = q.removeFirst().req
        queues[ch] = q
        start(next)
    }

    private func updateDucking() {
        let speaking = current[.pa] != nil || current[.copilot] != nil
        output.setDuck(speaking ? ambienceDuckLevel : 1, for: .ambience, fadeDuration: 0.6)
        let paDuck: Float = (duckPAForCopilot && current[.copilot] != nil) ? paDuckLevelForCopilot : 1
        output.setDuck(paDuck, for: .pa, fadeDuration: 0.25)
    }
}
