import Foundation
import Network
import Combine
import XCTest
@testable import AeroPACore

/// Exercises the real Network.framework listener over loopback.
final class AeroflyUDPProviderTests: XCTestCase {
    private func send(_ lines: [String], to port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: "127.0.0.1", port: p, using: .udp)
        conn.start(queue: .global())
        for l in lines { conn.send(content: Data(l.utf8), completion: .contentProcessed { _ in }) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { conn.cancel() }
    }

    private func randomPort() -> UInt16 { UInt16.random(in: 50_000...60_000) }

    func testReceivesValidatesAndNormalisesPackets() {
        let port = randomPort()
        let provider = AeroflyUDPProvider(port: port)
        var bag = Set<AnyCancellable>()
        let listening = expectation(description: "listening")
        let receiving = expectation(description: "receiving")
        let telemetry = expectation(description: "telemetry")
        var gotListening = false, gotReceiving = false, gotTelemetry = false
        var lastState: AircraftState?
        provider.connectionStatePublisher.sink { s in
            if case .listening = s, !gotListening { gotListening = true; listening.fulfill() }
            if case .receiving = s, !gotReceiving { gotReceiving = true; receiving.fulfill() }
        }.store(in: &bag)
        provider.telemetryPublisher.sink { s in
            lastState = s
            if !gotTelemetry && s.headingDegrees != nil { gotTelemetry = true; telemetry.fulfill() }
        }.store(in: &bag)

        provider.connect()
        wait(for: [listening], timeout: 5)
        XCTAssertFalse(provider.connectionState.isReceiving, "Listening without packets is not connected")

        send(["garbage", "XATTAerofly FS 4,270.0,1.0,0.0", "XGPSAerofly FS 4,-7.5898,33.3675,62.5,269.8,10.0"], to: port)
        wait(for: [receiving, telemetry], timeout: 5)
        XCTAssertEqual(lastState?.altitudeMSLFeet ?? 0, 205.05, accuracy: 0.1)
        XCTAssertEqual(lastState?.headingDegrees ?? 0, 270, accuracy: 0.01)
        XCTAssertEqual(lastState?.simulatorName, "Aerofly FS 4")
        provider.disconnect()
    }

    func testCountsRejectedPacketsInDiagnostics() {
        let port = randomPort()
        let provider = AeroflyUDPProvider(port: port)
        var bag = Set<AnyCancellable>()
        let rejected = expectation(description: "rejected counted")
        var done = false
        provider.diagnosticsPublisher.sink { d in
            if !done && d.rejectedCount >= 2 && d.acceptedCount >= 1 {
                done = true
                XCTAssertEqual(d.rejectionsByReason["unknownType"], 1)
                rejected.fulfill()
            }
        }.store(in: &bag)
        provider.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.send(["HELLO", "XGPSAerofly,1,2", "XATTAerofly FS 4,90,0,0"], to: port)
        }
        wait(for: [rejected], timeout: 6)
        provider.disconnect()
    }

    func testDetectsStaleAndLostThenRecovers() {
        let port = randomPort()
        let provider = AeroflyUDPProvider(port: port)
        provider.timeouts = ConnectionTimeouts(stale: 1, lost: 2)
        var bag = Set<AnyCancellable>()
        var seen: [String] = []
        let lost = expectation(description: "lost")
        let recovered = expectation(description: "recovered")
        var lostSeen = false, recoveredSeen = false
        provider.connectionStatePublisher.sink { s in
            seen.append(s.title)
            if case .lost = s, !lostSeen { lostSeen = true; lost.fulfill()
                self.send(["XGPSAerofly FS 4,-7.5898,33.3675,62.5,269.8,10.0"], to: port)
            }
            if case .receiving = s, lostSeen, !recoveredSeen { recoveredSeen = true; recovered.fulfill() }
        }.store(in: &bag)
        provider.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.send(["XGPSAerofly FS 4,-7.5898,33.3675,62.5,269.8,10.0"], to: port)
        }
        wait(for: [lost, recovered], timeout: 10)
        XCTAssertTrue(seen.contains("Signal interrupted"), "Stale state precedes lost: \(seen)")
        provider.disconnect()
    }

    func testDisconnectReportsDisconnected() {
        let provider = AeroflyUDPProvider(port: randomPort())
        var bag = Set<AnyCancellable>()
        let disc = expectation(description: "disconnected")
        var listened = false, done = false
        provider.connectionStatePublisher.sink { s in
            if case .listening = s { listened = true; provider.disconnect() }
            if case .disconnected = s, listened, !done { done = true; disc.fulfill() }
        }.store(in: &bag)
        provider.connect()
        wait(for: [disc], timeout: 5)
    }

    func testErrorMapping() {
        XCTAssertEqual(AeroflyUDPProvider.map(.dns(-65570), port: 1), .localNetworkDenied)
        XCTAssertEqual(AeroflyUDPProvider.map(.posix(.EADDRINUSE), port: 49002), .portUnavailable(49002))
    }
}
