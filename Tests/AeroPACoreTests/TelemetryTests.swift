import Foundation
import XCTest
@testable import AeroPACore

final class ForeFlightParserTests: XCTestCase {
    func testParsesGPS() throws {
        let msg = try ForeFlightMessageParser.parse("XGPSAerofly FS 4,-7.5898,33.3675,62.5,269.8,77.17\r\n")
        guard case .gps(let g) = msg else { return XCTFail("expected GPS") }
        XCTAssertEqual(g.simulatorName, "Aerofly FS 4")
        XCTAssertEqual(g.longitude, -7.5898, accuracy: 1e-9)
        XCTAssertEqual(g.latitude, 33.3675, accuracy: 1e-9)
        XCTAssertEqual(g.altitudeMetres, 62.5, accuracy: 1e-9)
        XCTAssertEqual(g.trackDegrees, 269.8, accuracy: 1e-9)
        XCTAssertEqual(g.groundSpeedMetresPerSecond, 77.17, accuracy: 1e-9)
    }

    func testParsesAttitudeWithExtraFields() throws {
        let msg = try ForeFlightMessageParser.parse("XATTAerofly FS 4,312.0,2.4,-18.0,0,0,0,0,0,0,0,0,0")
        guard case .attitude(let a) = msg else { return XCTFail("expected XATT") }
        XCTAssertEqual(a.headingDegrees, 312, accuracy: 1e-9)
        XCTAssertEqual(a.pitchDegrees, 2.4, accuracy: 1e-9)
        XCTAssertEqual(a.rollDegrees, -18, accuracy: 1e-9)
    }

    func testParsesTraffic() throws {
        let msg = try ForeFlightMessageParser.parse("XTRAFFICAerofly FS 4,a1b2c3,33.40,-7.60,3500,-700,1,90,180,RAM205")
        guard case .traffic(let t) = msg else { return XCTFail("expected traffic") }
        XCTAssertEqual(t.callsign, "RAM205")
        XCTAssertTrue(t.airborne)
    }

    func testNormalisesNegativeTrack() throws {
        let msg = try ForeFlightMessageParser.parse("XGPSAerofly FS 4,-7.5898,33.3675,62.5,-90.0,0.0")
        guard case .gps(let g) = msg else { return XCTFail() }
        XCTAssertEqual(g.trackDegrees, 270, accuracy: 1e-9)
    }

    func testAllValidFixturesParse() throws {
        let lines = try TestPaths.fixtureLines("valid_packets.txt")
        XCTAssertGreaterThan(lines.count, 5)
        for line in lines { XCTAssertNoThrow(try ForeFlightMessageParser.parse(line), line) }
    }

    func testAllInvalidFixturesRejectWithExpectedReason() throws {
        let lines = try TestPaths.fixtureLines("invalid_packets.txt")
        XCTAssertGreaterThan(lines.count, 8)
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2)
            XCTAssertThrowsError(try ForeFlightMessageParser.parse(parts[1]), line) { error in
                XCTAssertEqual((error as? PacketValidationError)?.reasonKey, parts[0], line)
            }
        }
    }

    func testRejectsEmptyOversizedAndBinary() {
        XCTAssertThrowsError(try ForeFlightMessageParser.parse(Data())) { XCTAssertEqual($0 as? PacketValidationError, .empty) }
        let big = Data(repeating: 0x41, count: 600)
        XCTAssertThrowsError(try ForeFlightMessageParser.parse(big)) { XCTAssertEqual($0 as? PacketValidationError, .tooLarge(600)) }
        XCTAssertThrowsError(try ForeFlightMessageParser.parse(Data([0xFF, 0xFE, 0x00, 0xC3]))) {
            XCTAssertEqual($0 as? PacketValidationError, .notText)
        }
    }
}

final class TelemetryNormalizerTests: XCTestCase {
    func gps(_ altM: Double, gsMS: Double = 70) -> ForeFlightMessage {
        .gps(.init(simulatorName: "Aerofly FS 4", longitude: 2, latitude: 49, altitudeMetres: altM, trackDegrees: 90, groundSpeedMetresPerSecond: gsMS))
    }

    func testNoStateBeforeFirstGPS() {
        let n = TelemetryNormalizer()
        XCTAssertNil(n.ingest(.attitude(.init(simulatorName: "x", headingDegrees: 90, pitchDegrees: 0, rollDegrees: 0)), at: 0))
    }

    func testUnitConversion() throws {
        let n = TelemetryNormalizer()
        let s = try XCTUnwrap(n.ingest(gps(1000, gsMS: 100), at: 0))
        XCTAssertEqual(s.altitudeMSLFeet ?? 0, 3280.84, accuracy: 0.01)
        XCTAssertEqual(s.groundSpeedKnots ?? 0, 194.38, accuracy: 0.01)
        XCTAssertNil(s.indicatedAirspeedKnots, "IAS is never invented")
        XCTAssertNil(s.onGround)
        XCTAssertNil(s.gearPosition)
    }

    func testDerivesVerticalSpeedFromAltitudeSlope() throws {
        let n = TelemetryNormalizer()
        // Climbing 1,500 ft/min = 25 ft/s = 7.62 m/s, sampled at 1 Hz with jitter-free data.
        var last: AircraftState?
        for i in 0..<5 { last = n.ingest(gps(100 + 7.62 * Double(i)), at: Double(i)) }
        let s = try XCTUnwrap(last)
        XCTAssertTrue(s.verticalSpeedIsDerived)
        XCTAssertEqual(s.verticalSpeedFPM ?? 0, 1500, accuracy: 5)
    }

    func testMergesFreshAttitudeAndDropsStaleAttitude() throws {
        let n = TelemetryNormalizer()
        n.ingest(.attitude(.init(simulatorName: "x", headingDegrees: 123, pitchDegrees: 4, rollDegrees: -2)), at: 0)
        let fresh = try XCTUnwrap(n.ingest(gps(100), at: 1))
        XCTAssertEqual(fresh.headingDegrees, 123)
        let stale = try XCTUnwrap(n.ingest(gps(100), at: 10))
        XCTAssertNil(stale.headingDegrees, "Old attitude must not be presented as current")
    }

    func testTrafficIsNotOwnship() {
        let n = TelemetryNormalizer()
        let t = ForeFlightMessage.traffic(.init(simulatorName: "x", icaoAddress: "a", latitude: 1, longitude: 1, altitudeFeet: 1,
                                                verticalSpeedFPM: 0, airborne: true, headingDegrees: 0, speedKnots: 100, callsign: "X"))
        XCTAssertNil(n.ingest(t, at: 0))
    }
}

final class ConnectionLivenessTests: XCTestCase {
    func testStateProgressionAndRecovery() {
        var t = ConnectionLivenessTracker(timeouts: ConnectionTimeouts(stale: 3, lost: 15))
        XCTAssertEqual(t.state(at: 0, port: 49002), .listening(port: 49002), "No packets is never 'connected'")
        t.recordPacket(at: 1)
        XCTAssertEqual(t.state(at: 2, port: 49002), .receiving)
        XCTAssertEqual(t.state(at: 5, port: 49002), .stale(secondsSinceLastPacket: 4))
        XCTAssertEqual(t.state(at: 17, port: 49002), .lost)
        t.recordPacket(at: 18)
        XCTAssertEqual(t.state(at: 18.5, port: 49002), .receiving, "Recovers on the next valid packet")
    }

    func testPacketRate() {
        var t = ConnectionLivenessTracker()
        for i in 0..<20 { t.recordPacket(at: 100 + Double(i) * 0.25) } // 4 Hz for 5 s
        XCTAssertEqual(t.packetsPerSecond(at: 104.75), 4, accuracy: 0.5)
        XCTAssertEqual(t.packetsPerSecond(at: 200), 0)
    }
}
