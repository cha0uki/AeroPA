import Foundation
import AVFoundation

/// Owns AVAudioSession policy (iOS). On macOS (tests) it's a no-op.
///
/// Policy:
/// * Category `.playback` with `.mixWithOthers`: AeroPA plays alongside Aerofly and never
///   interrupts or ducks it. Our own channels duck each other internally.
/// * `.playback` keeps working with the silent switch on and on the lock screen.
///   With the `audio` background mode, the app keeps running while it's actually
///   playing (ambience loop or announcements).
/// * AirPlay and Bluetooth A2DP routes are allowed by `.playback` by default.
/// * Interruptions (calls, Siri, alarms) suspend the scheduler and resume after.
public final class AudioSessionManager {
    public enum Event: Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(String)
        case mediaServicesReset
    }

    public var onEvent: ((Event) -> Void)?
    private var observers: [NSObjectProtocol] = []
    public private(set) var lastError: String?

    public init() {}

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    @discardableResult
    public func activate() -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            installObservers()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
        #else
        return true
        #endif
    }

    public func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    public var currentRouteDescription: String {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.map { "\($0.portName)" }.joined(separator: ", ")
        #else
        return "System output"
        #endif
    }

    #if os(iOS)
    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self?.onEvent?(.interruptionBegan)
            case .ended:
                let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let resume = AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume)
                if resume { try? session.setActive(true) }
                self?.onEvent?(.interruptionEnded(shouldResume: resume))
            @unknown default: break
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            self?.onEvent?(.routeChanged(self?.currentRouteDescription ?? ""))
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            _ = self?.activate()
            self?.onEvent?(.mediaServicesReset)
        })
    }
    #endif
}
