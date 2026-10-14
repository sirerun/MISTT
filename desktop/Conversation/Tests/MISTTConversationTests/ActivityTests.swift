import XCTest
@testable import MISTTConversation
final class ActivityTests: XCTestCase {
    func testHysteresisAndThinkingPauseObservation() {
        var detector = ActivityDetector()
        let loud = Data(repeating: 32, count: 320) // little-endian 0x2020
        let quiet = Data(repeating: 0, count: 320)
        XCTAssertNil(detector.consume(loud)); XCTAssertNil(detector.consume(loud))
        XCTAssertEqual(detector.consume(loud), true)
        for _ in 0..<29 { XCTAssertNil(detector.consume(quiet)) }
        XCTAssertEqual(detector.consume(quiet), false)
        // Speech resumption is a new activity observation, never an endpoint.
        XCTAssertNil(detector.consume(loud)); XCTAssertNil(detector.consume(loud))
        XCTAssertEqual(detector.consume(loud), true)
    }
}

final class CaptureLeaseTests: XCTestCase {
    func testCompetingCaptureFailsAndReleaseAllowsFreshOwner() throws {
        var first: CaptureLease? = try CaptureLease.acquire()
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try CaptureLease.acquire())
        first = nil
        let next = try CaptureLease.acquire()
        try withExtendedLifetime(next) { XCTAssertThrowsError(try CaptureLease.acquire()) }
    }
}
