// Minimal XCTest-compatible shim used ONLY by Tools/run_tests_without_xcode.sh on
// machines that have the Swift toolchain but no Xcode (Command Line Tools ships no
// XCTest). In Xcode, the real XCTest framework is used and this file is not built.
import Foundation

public var _xctFailures: [String] = []
public var _xctCurrentTest = ""

open class XCTestCase {
    public required init() {}
    open func setUp() {}
    open func tearDown() {}

    public func expectation(description: String) -> XCTestExpectation { XCTestExpectation(description: description) }

    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && expectations.contains(where: { !$0.isFulfilled }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        for e in expectations where !e.isFulfilled { _xctRecord("Asynchronous wait failed: \(e.description)", #file, #line) }
    }
}

public final class XCTestExpectation {
    public let description: String
    public private(set) var isFulfilled = false
    init(description: String) { self.description = description }
    public func fulfill() { isFulfilled = true }
}

public func _xctRecord(_ message: String, _ file: StaticString, _ line: UInt) {
    _xctFailures.append("\(_xctCurrentTest): \(message) (\(("\(file)" as NSString).lastPathComponent):\(line))")
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) { _xctRecord("XCTFail \(message)", file, line) }

public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !e() { _xctRecord("XCTAssertTrue failed \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try e() { _xctRecord("XCTAssertFalse failed \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { _xctRecord("XCTAssertEqual failed: (\(x)) != (\(y)) \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if abs(x - y) > accuracy { _xctRecord("XCTAssertEqual failed: (\(x)) != (\(y)) ± \(accuracy) \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if let v = try e() { _xctRecord("XCTAssertNil failed: \(v) \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try e() == nil { _xctRecord("XCTAssertNotNil failed \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if !(x > y) { _xctRecord("XCTAssertGreaterThan failed: \(x) <= \(y) \(m())", file, line) } } catch { _xctRecord("threw \(error)", file, line) }
}
public func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try e() } catch { _xctRecord("XCTAssertNoThrow failed: \(error) \(m())", file, line) }
}
public func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try e(); _xctRecord("XCTAssertThrowsError: no error \(m())", file, line) } catch { handler(error) }
}
public struct XCTUnwrapError: Error { let message: String }
public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v = try e() else { _xctRecord("XCTUnwrap failed \(m())", file, line); throw XCTUnwrapError(message: m()) }
    return v
}
