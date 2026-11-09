import Foundation
import Combine

/// Simulator-free telemetry for demo mode, development and tests.
/// `isSimulated` is always true, so the UI labels it DEMO and never shows it as an Aerofly connection.
public final class MockTelemetryProvider: SimulatorTelemetryProvider {
    public enum Mode: String, CaseIterable, Sendable {
        /// Flies `DemoFlightScript` from gate to gate.
        case scripted
        /// Holds values the developer sets with `manualOverride`.
        case manual
    }

    public let displayName = "Demo flight"
    public let isSimulated = true

    /// When true, only the fields Aerofly's broadcast really carries are emitted.
    /// Use it to rehearse the real-device experience.
    public var emulateBroadcastFields: Bool {
        didSet { capabilitiesDidChange() }
    }
    public private(set) var capabilities: Set<TelemetryCapability>

    public var mode: Mode = .scripted
    /// Simulated seconds per real second.
    public var timeScale: Double = 1
    public var aircraftName = "Airbus A320"
    public private(set) var script: DemoFlightScript
    public private(set) var isPaused = false

    /// Manual-mode values; also applied on top of the script when set.
    public struct ManualValues: Equatable, Sendable {
        public var altitudeFeet: Double = 300
        public var groundSpeedKnots: Double = 0
        public var verticalSpeedFPM: Double = 0
        public var headingDegrees: Double = 90
        public var onGround = true
        public var gearDown = true
        public var flaps: Double = 0
        public var enginesRunning = false
        public init() {}
    }
    public var manual = ManualValues()

    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    private let telemetrySubject = PassthroughSubject<AircraftState, Never>()
    private let diagnosticsSubject = CurrentValueSubject<TelemetryDiagnostics, Never>(TelemetryDiagnostics())
    private var timer: Timer?
    /// Monotonic provider clock. It never goes backwards across mode switches or restarts.
    private var clock: TimeInterval = 0
    private var diagnostics = TelemetryDiagnostics()
    public private(set) var currentAircraftState: AircraftState?
    private let tickInterval: TimeInterval

    public var connectionState: ConnectionState { stateSubject.value }
    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { stateSubject.eraseToAnyPublisher() }
    public var telemetryPublisher: AnyPublisher<AircraftState, Never> { telemetrySubject.eraseToAnyPublisher() }
    public var diagnosticsPublisher: AnyPublisher<TelemetryDiagnostics, Never> { diagnosticsSubject.eraseToAnyPublisher() }

    public init(parameters: DemoFlightScript.Parameters = .init(), emulateBroadcastFields: Bool = false, tickInterval: TimeInterval = 0.2) {
        self.script = DemoFlightScript(parameters: parameters)
        self.emulateBroadcastFields = emulateBroadcastFields
        self.capabilities = emulateBroadcastFields ? .foreFlightBroadcast : .full
        self.tickInterval = tickInterval
        diagnostics.simulatorName = "AeroPA Demo"
    }

    private func capabilitiesDidChange() {
        capabilities = emulateBroadcastFields ? .foreFlightBroadcast : .full
    }

    public func connect() {
        guard timer == nil else { return }
        stateSubject.send(.receiving)
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func disconnect() {
        timer?.invalidate()
        timer = nil
        stateSubject.send(.disconnected)
    }

    public func setPaused(_ paused: Bool) { isPaused = paused }

    public func restartFlight() {
        script = DemoFlightScript(parameters: script.parameters)
    }

    public func jump(to leg: DemoFlightScript.Leg) { script.jump(to: leg) }

    /// Changes the scripted aircraft (e.g. rotate at the selected profile's Vr) and restarts the flight.
    public func updateParameters(_ parameters: DemoFlightScript.Parameters) {
        guard parameters != script.parameters else { return }
        script = DemoFlightScript(parameters: parameters)
    }

    /// Advances manually by `seconds` of simulated time (also usable from tests).
    public func advance(by seconds: TimeInterval) {
        let steps = max(1, Int(seconds / 0.5))
        for _ in 0..<steps { produce(dt: seconds / Double(steps)) }
    }

    private func tick() {
        guard !isPaused else { return }
        produce(dt: tickInterval * timeScale)
    }

    private func produce(dt: TimeInterval) {
        var state: AircraftState
        clock += dt
        switch mode {
        case .scripted:
            script.step(dt)
            state = script.aircraftState(emulateBroadcastFields: emulateBroadcastFields, aircraftName: aircraftName)
        case .manual:
            var s = AircraftState(time: clock,
                                  latitude: script.latitude, longitude: script.longitude,
                                  altitudeMSLFeet: manual.altitudeFeet, groundSpeedKnots: manual.groundSpeedKnots,
                                  trackDegrees: manual.headingDegrees, headingDegrees: manual.headingDegrees,
                                  pitchDegrees: 0, rollDegrees: 0,
                                  verticalSpeedFPM: manual.verticalSpeedFPM,
                                  verticalSpeedIsDerived: emulateBroadcastFields,
                                  simulatorName: "AeroPA Demo")
            if !emulateBroadcastFields {
                s.indicatedAirspeedKnots = manual.groundSpeedKnots
                s.onGround = manual.onGround
                s.gearPosition = manual.gearDown ? 1 : 0
                s.flapsPosition = manual.flaps
                s.enginesRunning = manual.enginesRunning
                s.aircraftName = aircraftName
            }
            state = s
        }
        state.time = clock
        currentAircraftState = state
        diagnostics.acceptedCount += 1
        diagnostics.packetsPerSecond = 1 / tickInterval
        diagnostics.lastPacketWallClock = Date()
        telemetrySubject.send(state)
        if diagnostics.acceptedCount % 5 == 0 { diagnosticsSubject.send(diagnostics) }
    }

    /// Copies the script's current values into manual mode, so a switch to manual doesn't jump.
    public func captureManualFromScript() {
        manual.altitudeFeet = script.altitudeFeet
        manual.groundSpeedKnots = script.groundSpeed
        manual.verticalSpeedFPM = script.verticalSpeed
        manual.headingDegrees = script.heading
        manual.onGround = script.onGround
        manual.gearDown = script.gear > 0.5
        manual.flaps = script.flaps
        manual.enginesRunning = script.engines
    }
}
