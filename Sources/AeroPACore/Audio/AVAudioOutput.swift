import Foundation
import AVFoundation

/// AVAudioEngine implementation of `AudioOutput`.
///
/// Graph (one chain per channel):
///   PA:       player → EQ ("cabin speaker" band-pass) → mixer ┐
///   Copilot:  player → EQ ("interphone" band-pass)    → mixer ┤
///   Ambience: playerA/playerB (crossfade)              → mixer ┼→ mainMixer → output
///   SFX:      3 pooled players (overlapping one-shots) → mixer ┘
///
/// Each mixer's volume is user volume × duck × fade. Everything runs on main.
/// Synthesised speech goes through `AVSpeechSynthesizer.write`, so it uses the
/// same mixer, volume and EQ as recordings.
public final class AVAudioOutput: AudioOutput {
    public struct Effects: Equatable, Sendable {
        public var paSpeakerEffect = true
        public var copilotInterphoneEffect = true
        public init() {}
    }

    public let format: AVAudioFormat
    private let engine = AVAudioEngine()
    private var mixers: [AudioChannel: AVAudioMixerNode] = [:]
    private var players: [AudioChannel: [AVAudioPlayerNode]] = [:]
    private var eqs: [AudioChannel: AVAudioUnitEQ] = [:]
    private var userVolume: [AudioChannel: Float] = [:]
    private var duck: [AudioChannel: (current: Float, target: Float, step: Float)] = [:]
    private var fade: [AudioChannel: (current: Float, target: Float, step: Float, then: (() -> Void)?)] = [:]
    private var rampTimer: Timer?
    private var bufferCache: [URL: AVAudioPCMBuffer] = [:]
    private var cacheOrder: [URL] = []
    private let cacheLimit = 24
    private var sfxIndex = 0
    private var ambienceActive = 0
    private var synthesizers: [ObjectIdentifier: AVSpeechSynthesizer] = [:]
    private var configObserver: NSObjectProtocol?
    public private(set) var lastError: AudioPlaybackError?
    public var effects = Effects() { didSet { applyEffects() } }

    public init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) ?? engine.mainMixerNode.outputFormat(forBus: 0)
        buildGraph()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // Route change (AirPlay, Bluetooth, headphones): the engine stops itself; restart.
            self?.startEngineIfNeeded()
        }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        rampTimer?.invalidate()
        engine.stop()
    }

    // MARK: - Graph

    private func buildGraph() {
        let counts: [AudioChannel: Int] = [.pa: 1, .copilot: 1, .ambience: 2, .sfx: 3]
        for ch in AudioChannel.allCases {
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
            mixers[ch] = mixer
            userVolume[ch] = 0.8
            duck[ch] = (1, 1, 0)
            fade[ch] = (1, 1, 0, nil)
            var nodes: [AVAudioPlayerNode] = []
            for _ in 0..<(counts[ch] ?? 1) {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                if ch == .pa || ch == .copilot {
                    let eq = eqs[ch] ?? makeEQ(for: ch)
                    if eqs[ch] == nil {
                        eqs[ch] = eq
                        engine.attach(eq)
                        engine.connect(eq, to: mixer, format: format)
                    }
                    engine.connect(p, to: eq, format: format)
                } else {
                    engine.connect(p, to: mixer, format: format)
                }
                nodes.append(p)
            }
            players[ch] = nodes
        }
        applyEffects()
        applyVolumes()
    }

    private func makeEQ(for ch: AudioChannel) -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let (low, high, peak): (Float, Float, Float) = ch == .pa ? (280, 5_500, 2_200) : (400, 3_400, 1_800)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = low
        eq.bands[1].filterType = .lowPass
        eq.bands[1].frequency = high
        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = peak
        eq.bands[2].bandwidth = 1.2
        eq.bands[2].gain = ch == .pa ? 3 : 4
        return eq
    }

    private func applyEffects() {
        eqs[.pa]?.bypass = !effects.paSpeakerEffect
        eqs[.copilot]?.bypass = !effects.copilotInterphoneEffect
    }

    @discardableResult
    public func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            lastError = .engineUnavailable(error.localizedDescription)
            return false
        }
    }

    public func pauseEngine() { engine.pause() }

    // MARK: - AudioOutput

    public func play(_ source: AudioSource, on channel: AudioChannel, loops: Bool,
                     completion: @escaping (Result<Void, AudioPlaybackError>) -> Void) {
        guard startEngineIfNeeded() else {
            completion(.failure(lastError ?? .engineUnavailable("start failed")))
            return
        }
        switch source {
        case .file(let url):
            do {
                let buffer = try loadBuffer(url)
                schedule(buffer, on: channel, loops: loops, completion: completion)
            } catch let e as AudioPlaybackError {
                completion(.failure(e))
            } catch {
                completion(.failure(.decodeFailed(url.lastPathComponent)))
            }
        case .speech(let text, let lang):
            synthesize(text, language: lang) { [weak self] buffer in
                guard let self else { return }
                guard let buffer, buffer.frameLength > 0 else { completion(.failure(.speechUnavailable)); return }
                self.schedule(buffer, on: channel, loops: false, completion: completion)
            }
        }
    }

    public func stop(channel: AudioChannel, fadeDuration: TimeInterval) {
        let stopNow = { [weak self] in
            guard let self else { return }
            self.players[channel]?.forEach { $0.stop() }
            self.setFade(1, for: channel, duration: 0, then: nil)
        }
        if fadeDuration <= 0 { stopNow(); return }
        setFade(0, for: channel, duration: fadeDuration, then: stopNow)
    }

    public func setVolume(_ volume: Float, for channel: AudioChannel) {
        userVolume[channel] = max(0, min(1, volume))
        applyVolumes()
    }

    public func setDuck(_ multiplier: Float, for channel: AudioChannel, fadeDuration: TimeInterval) {
        let target = max(0, min(1, multiplier))
        let cur = duck[channel]?.current ?? 1
        guard abs(cur - target) > 0.001 || duck[channel]?.target != target else { return }
        let ticks = max(Float(fadeDuration * 30), 1)
        duck[channel] = (cur, target, abs(target - cur) / ticks)
        ensureRamp()
    }

    public func stopAll() {
        for ch in AudioChannel.allCases { players[ch]?.forEach { $0.stop() } }
    }

    // MARK: - Scheduling

    private func schedule(_ buffer: AVAudioPCMBuffer, on channel: AudioChannel, loops: Bool,
                          completion: @escaping (Result<Void, AudioPlaybackError>) -> Void) {
        guard let node = nextPlayer(for: channel) else { completion(.failure(.engineUnavailable("no player"))); return }
        if channel == .ambience {
            setFade(1, for: channel, duration: 0, then: nil)
        } else if channel != .sfx {
            node.stop()
            setFade(1, for: channel, duration: 0, then: nil)
        }
        let options: AVAudioPlayerNodeBufferOptions = loops ? [.loops] : []
        node.scheduleBuffer(buffer, at: nil, options: options, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { completion(.success(())) }
        }
        if !node.isPlaying { node.play() }
    }

    private func nextPlayer(for channel: AudioChannel) -> AVAudioPlayerNode? {
        guard let nodes = players[channel], !nodes.isEmpty else { return nil }
        switch channel {
        case .sfx:
            sfxIndex = (sfxIndex + 1) % nodes.count
            let n = nodes[sfxIndex]
            n.stop()
            return n
        case .ambience:
            let old = nodes[ambienceActive]
            ambienceActive = (ambienceActive + 1) % nodes.count
            let new = nodes[ambienceActive]
            new.stop()
            crossfade(from: old.isPlaying ? old : nil, to: new, duration: 1.5)
            return new
        default:
            return nodes[0]
        }
    }

    // MARK: - Decoding

    private func loadBuffer(_ url: URL) throws -> AVAudioPCMBuffer {
        if let b = bufferCache[url] { return b }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioPlaybackError.fileMissing(url.lastPathComponent) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioPlaybackError.decodeFailed(url.lastPathComponent) }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw AudioPlaybackError.decodeFailed(url.lastPathComponent)
        }
        do { try file.read(into: raw) } catch { throw AudioPlaybackError.decodeFailed(url.lastPathComponent) }
        guard let converted = Self.convert(raw, to: format) else { throw AudioPlaybackError.decodeFailed(url.lastPathComponent) }
        bufferCache[url] = converted
        cacheOrder.append(url)
        if cacheOrder.count > cacheLimit { bufferCache[cacheOrder.removeFirst()] = nil }
        return converted
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return out
    }

    // MARK: - Speech

    private func synthesize(_ text: String, language: String, completion: @escaping (AVAudioPCMBuffer?) -> Void) {
        let synth = AVSpeechSynthesizer()
        let key = ObjectIdentifier(synth)
        synthesizers[key] = synth
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.preUtteranceDelay = 0.15
        var chunks: [AVAudioPCMBuffer] = []
        var finished = false
        let target = format
        synth.write(utterance) { [weak self] buffer in
            guard !finished else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                // A zero-length buffer marks the end of the utterance.
                finished = true
                let joined = Self.concatenate(chunks, format: target)
                DispatchQueue.main.async {
                    self?.synthesizers[key] = nil
                    completion(joined)
                }
                return
            }
            if let c = Self.convert(pcm, to: target) { chunks.append(c) }
        }
    }

    static func concatenate(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let total = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let dst = out.floatChannelData else { return nil }
        var offset = 0
        for b in buffers {
            guard let src = b.floatChannelData else { continue }
            let n = Int(b.frameLength)
            for ch in 0..<Int(format.channelCount) {
                let srcCh = min(ch, Int(b.format.channelCount) - 1)
                (dst[ch] + offset).update(from: src[srcCh], count: n)
            }
            offset += n
        }
        out.frameLength = total
        return out
    }

    // MARK: - Volume ramps

    /// Equal-power crossfade between the two ambience players, so switching loops doesn't cut.
    private func crossfade(from old: AVAudioPlayerNode?, to new: AVAudioPlayerNode, duration: TimeInterval) {
        new.volume = 0
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { t in
            let x = Float(min(1, Date().timeIntervalSince(start) / duration))
            new.volume = sin(x * .pi / 2)
            old?.volume = cos(x * .pi / 2)
            if x >= 1 {
                t.invalidate()
                old?.stop()
                old?.volume = 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setFade(_ target: Float, for ch: AudioChannel, duration: TimeInterval, then: (() -> Void)?) {
        let cur = fade[ch]?.current ?? 1
        if duration <= 0 {
            fade[ch] = (target, target, 0, nil)
            applyVolumes()
            then?()
            return
        }
        let ticks = max(Float(duration * 30), 1)
        fade[ch] = (cur, target, abs(target - cur) / ticks, then)
        ensureRamp()
    }

    private func ensureRamp() {
        guard rampTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.rampTick() }
        RunLoop.main.add(t, forMode: .common)
        rampTimer = t
    }

    private func rampTick() {
        var active = false
        var callbacks: [() -> Void] = []
        for ch in AudioChannel.allCases {
            if var d = duck[ch], d.current != d.target {
                d.current = d.current < d.target ? min(d.target, d.current + d.step) : max(d.target, d.current - d.step)
                duck[ch] = d
                active = active || d.current != d.target
            }
            if var f = fade[ch], f.current != f.target {
                f.current = f.current < f.target ? min(f.target, f.current + f.step) : max(f.target, f.current - f.step)
                if f.current == f.target, let cb = f.then { callbacks.append(cb); f.then = nil }
                fade[ch] = f
                active = active || f.current != f.target
            }
        }
        applyVolumes()
        callbacks.forEach { $0() }
        if !active {
            rampTimer?.invalidate()
            rampTimer = nil
        }
    }

    private func applyVolumes() {
        for ch in AudioChannel.allCases {
            let v = (userVolume[ch] ?? 1) * (duck[ch]?.current ?? 1) * (fade[ch]?.current ?? 1)
            mixers[ch]?.outputVolume = v
        }
    }
}
