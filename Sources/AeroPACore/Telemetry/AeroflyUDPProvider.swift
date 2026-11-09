import Foundation
import Network
import Combine

/// Receives Aerofly's "Broadcast flight info to IP address" datagrams
/// (ForeFlight XGPS/XATT text protocol) with Network.framework.
///
/// Design notes:
/// * `NWListener` on UDP creates one `NWConnection` per remote endpoint, and
///   we read datagrams from each one.
/// * `allowLocalEndpointReuse` lets AeroPA share the port with an EFB app
///   that also listens on 49002.
/// * Liveness comes from packet arrival only. The state never becomes
///   `.receiving` until a datagram passes validation.
/// * When the listener fails (Wi-Fi change, app suspension) it restarts
///   with exponential backoff.
public final class AeroflyUDPProvider: SimulatorTelemetryProvider {
    public static let defaultPort: UInt16 = 49002

    public let displayName = "Aerofly FS (UDP)"
    public let isSimulated = false
    public let capabilities: Set<TelemetryCapability> = .foreFlightBroadcast

    public private(set) var port: UInt16
    public var timeouts: ConnectionTimeouts {
        get { liveness.timeouts }
        set { liveness.timeouts = newValue }
    }

    private let queue = DispatchQueue(label: "aeropa.udp", qos: .userInitiated)
    private let timeSource: TimeSource
    private let normalizer = TelemetryNormalizer()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var liveness = ConnectionLivenessTracker()
    private var watchdog: DispatchSourceTimer?
    private var wantsConnection = false
    private var restartAttempt = 0
    private var diagnostics = TelemetryDiagnostics()
    private var lastDiagnosticsPublish: TimeInterval = 0
    /// Last state published, owned by `queue`. Main-thread subscribers read `stateSubject`.
    private var queueState: ConnectionState = .disconnected

    // Published on main.
    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    private let telemetrySubject = PassthroughSubject<AircraftState, Never>()
    private let diagnosticsSubject = CurrentValueSubject<TelemetryDiagnostics, Never>(TelemetryDiagnostics())
    public private(set) var currentAircraftState: AircraftState?

    public var connectionState: ConnectionState { stateSubject.value }
    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { stateSubject.removeDuplicates().eraseToAnyPublisher() }
    public var telemetryPublisher: AnyPublisher<AircraftState, Never> { telemetrySubject.eraseToAnyPublisher() }
    public var diagnosticsPublisher: AnyPublisher<TelemetryDiagnostics, Never> { diagnosticsSubject.eraseToAnyPublisher() }

    public init(port: UInt16 = AeroflyUDPProvider.defaultPort, timeSource: TimeSource = SystemTimeSource()) {
        self.port = port
        self.timeSource = timeSource
    }

    deinit {
        listener?.cancel()
        watchdog?.cancel()
    }

    // MARK: - Lifecycle

    public func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = true
            self.restartAttempt = 0
            self.startListener()
            self.startWatchdog()
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.teardown()
            self.watchdog?.cancel()
            self.watchdog = nil
            self.liveness.reset()
            self.normalizer.reset()
            self.publishState(.disconnected)
        }
    }

    /// Changes the port and restarts if currently connected.
    public func setPort(_ newPort: UInt16) {
        queue.async { [weak self] in
            guard let self, newPort != self.port else { return }
            self.port = newPort
            if self.wantsConnection {
                self.teardown()
                self.startListener()
            }
        }
    }

    /// Restarts the listener when the app returns to the foreground; iOS may
    /// have torn the socket down while the app was suspended.
    public func refreshAfterForeground() {
        queue.async { [weak self] in
            guard let self, self.wantsConnection else { return }
            if self.listener == nil || self.listener?.state != .ready {
                self.teardown()
                self.startListener()
            }
        }
    }

    // MARK: - Listener (queue-confined)

    private func startListener() {
        guard wantsConnection, listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            publishState(.failed(.portUnavailable(port)))
            return
        }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        do {
            let l = try NWListener(using: params, on: nwPort)
            l.stateUpdateHandler = { [weak self] in self?.handleListenerState($0) }
            l.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener = l
            l.start(queue: queue)
            diagnostics.listeningPort = port
        } catch {
            publishState(.failed(.listenerFailed(error.localizedDescription)))
            scheduleRestart()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            restartAttempt = 0
            publishState(liveness.state(at: timeSource.now, port: port))
        case .waiting(let error), .failed(let error):
            let mapped = Self.map(error, port: port)
            publishState(.failed(mapped))
            if case .failed = state {
                teardown()
                scheduleRestart()
            }
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    /// Maps Network.framework errors. iOS reports a local-network denial as
    /// `kDNSServiceErr_PolicyDenied` (-65570), or on some versions as a POSIX error.
    static func map(_ error: NWError, port: UInt16) -> ConnectionError {
        switch error {
        case .dns(let code) where code == -65570:
            return .localNetworkDenied
        case .posix(let code) where code == .EADDRINUSE:
            return .portUnavailable(port)
        case .posix(let code) where code == .EACCES || code == .EPERM:
            return .localNetworkDenied
        default:
            return .listenerFailed(error.debugDescription)
        }
    }

    private func scheduleRestart() {
        guard wantsConnection else { return }
        restartAttempt += 1
        diagnostics.listenerRestarts += 1
        let delay = min(pow(2, Double(min(restartAttempt, 5))), 30) // 2,4,8,16,30s
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsConnection, self.listener == nil else { return }
            self.startListener()
        }
    }

    private func teardown() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: key)
            default: break
            }
            _ = connection
        }
        connection.start(queue: queue)
        receive(on: connection)
        if case .hostPort(let host, _) = connection.endpoint {
            diagnostics.lastSenderAddress = "\(host)"
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handleDatagram(data) }
            if error == nil, let connection, connection.state != .cancelled {
                self.receive(on: connection)
            }
        }
    }

    // MARK: - Datagram handling (queue-confined)

    /// Visible for tests: feeds one datagram through validation and normalisation.
    func handleDatagram(_ data: Data) {
        let now = timeSource.now
        do {
            let message = try ForeFlightMessageParser.parse(data)
            liveness.recordPacket(at: now)
            diagnostics.acceptedCount += 1
            diagnostics.countsByType[message.typeKey, default: 0] += 1
            diagnostics.lastPacketWallClock = Date()
            diagnostics.lastPacketText = String(decoding: data.prefix(160), as: UTF8.self)
            diagnostics.simulatorName = message.simulatorName
            if let state = normalizer.ingest(message, at: now) {
                DispatchQueue.main.async { [weak self] in
                    self?.currentAircraftState = state
                    self?.telemetrySubject.send(state)
                }
            }
            if !queueState.isReceiving { publishState(.receiving) }
        } catch let error as PacketValidationError {
            diagnostics.rejectedCount += 1
            diagnostics.rejectionsByReason[error.reasonKey, default: 0] += 1
            diagnostics.lastRejection = error.description
        } catch {
            diagnostics.rejectedCount += 1
        }
        publishDiagnosticsThrottled(now: now)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    private func watchdogTick() {
        guard wantsConnection else { return }
        let now = timeSource.now
        if listener?.state == .ready {
            let s = liveness.state(at: now, port: port)
            publishState(s)
            if case .lost = s { normalizer.reset() }
        }
        diagnostics.packetsPerSecond = liveness.packetsPerSecond(at: now)
        publishDiagnostics()
    }

    private func publishDiagnosticsThrottled(now: TimeInterval) {
        guard now - lastDiagnosticsPublish > 0.25 else { return }
        lastDiagnosticsPublish = now
        diagnostics.packetsPerSecond = liveness.packetsPerSecond(at: now)
        publishDiagnostics()
    }

    private func publishDiagnostics() {
        let d = diagnostics
        DispatchQueue.main.async { [weak self] in self?.diagnosticsSubject.send(d) }
    }

    private func publishState(_ state: ConnectionState) {
        guard state != queueState else { return }
        queueState = state
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stateSubject.value != state else { return }
            self.stateSubject.send(state)
        }
    }
}
