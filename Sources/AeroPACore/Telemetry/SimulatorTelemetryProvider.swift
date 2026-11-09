import Foundation
import Combine

public enum ConnectionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// iOS reported the local-network policy denial (Settings › Privacy › Local Network).
    case localNetworkDenied
    case portUnavailable(UInt16)
    case listenerFailed(String)

    public var description: String {
        switch self {
        case .localNetworkDenied:
            return "Local network access is off for AeroPA. Turn it on in Settings › Privacy & Security › Local Network."
        case .portUnavailable(let p):
            return "UDP port \(p) is unavailable. Another app may be using it exclusively."
        case .listenerFailed(let m):
            return "Network listener failed: \(m)"
        }
    }
}

/// Connection state shown in the UI. There's no connected state without packets:
/// `.receiving` is only reported after valid datagrams have arrived.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    /// The listener is open and waiting for the first valid packet.
    case listening(port: UInt16)
    /// Valid telemetry is arriving.
    case receiving
    /// Packets stopped briefly; the last state is still shown but flagged.
    case stale(secondsSinceLastPacket: Double)
    /// No packets for a long time; the listener stays open to recover.
    case lost
    case failed(ConnectionError)

    public var isReceiving: Bool { if case .receiving = self { return true }; return false }

    public var title: String {
        switch self {
        case .disconnected: return "Not connected"
        case .listening: return "Searching for simulator"
        case .receiving: return "Connected"
        case .stale: return "Signal interrupted"
        case .lost: return "Connection lost"
        case .failed: return "Connection failed"
        }
    }
}

/// Live diagnostics for the Connection screen.
public struct TelemetryDiagnostics: Equatable, Sendable {
    public var listeningPort: UInt16?
    public var lastPacketWallClock: Date?
    public var lastPacketText: String?
    public var lastSenderAddress: String?
    public var packetsPerSecond: Double = 0
    public var acceptedCount: Int = 0
    public var rejectedCount: Int = 0
    public var countsByType: [String: Int] = [:]
    public var rejectionsByReason: [String: Int] = [:]
    public var lastRejection: String?
    public var simulatorName: String?
    public var listenerRestarts: Int = 0

    public init() {}

    public var looksLikeAerofly: Bool {
        simulatorName?.lowercased().contains("aerofly") ?? false
    }
}

/// The abstraction between simulator integration and flight logic.
/// Implementations publish on the main queue.
public protocol SimulatorTelemetryProvider: AnyObject {
    /// Human-readable source, e.g. "Aerofly FS (UDP)" or "Demo flight".
    var displayName: String { get }
    /// True for providers that never touch a real simulator. The UI shows a DEMO badge.
    var isSimulated: Bool { get }
    /// Fields this provider can supply.
    var capabilities: Set<TelemetryCapability> { get }

    var connectionState: ConnectionState { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }

    /// Every fused state update.
    var telemetryPublisher: AnyPublisher<AircraftState, Never> { get }
    var currentAircraftState: AircraftState? { get }

    var diagnosticsPublisher: AnyPublisher<TelemetryDiagnostics, Never> { get }

    func connect()
    func disconnect()
}

/// Thresholds for stale and lost detection.
public struct ConnectionTimeouts: Equatable, Sendable {
    public var stale: TimeInterval = 3
    public var lost: TimeInterval = 15
    public init(stale: TimeInterval = 3, lost: TimeInterval = 15) {
        self.stale = stale
        self.lost = lost
    }
}

/// Pure state logic for liveness and packet rate, separate from the socket so it can be unit-tested.
public struct ConnectionLivenessTracker {
    public var timeouts: ConnectionTimeouts
    public private(set) var lastPacketTime: TimeInterval?
    private var recentPacketTimes: [TimeInterval] = []
    public let rateWindow: TimeInterval = 5

    public init(timeouts: ConnectionTimeouts = ConnectionTimeouts()) {
        self.timeouts = timeouts
    }

    public mutating func recordPacket(at time: TimeInterval) {
        lastPacketTime = time
        recentPacketTimes.append(time)
        recentPacketTimes.removeAll { $0 < time - rateWindow }
    }

    public mutating func reset() {
        lastPacketTime = nil
        recentPacketTimes.removeAll()
    }

    public func packetsPerSecond(at time: TimeInterval) -> Double {
        let recent = recentPacketTimes.filter { $0 >= time - rateWindow }
        guard let first = recent.first, recent.count > 1 else { return recent.isEmpty ? 0 : 1 / rateWindow }
        let span = max(time - first, 1)
        return Double(recent.count) / span
    }

    /// State while the listener is up.
    public func state(at time: TimeInterval, port: UInt16) -> ConnectionState {
        guard let last = lastPacketTime else { return .listening(port: port) }
        let age = time - last
        if age >= timeouts.lost { return .lost }
        if age >= timeouts.stale { return .stale(secondsSinceLastPacket: age) }
        return .receiving
    }
}

public protocol TimeSource {
    /// Monotonic seconds.
    var now: TimeInterval { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
