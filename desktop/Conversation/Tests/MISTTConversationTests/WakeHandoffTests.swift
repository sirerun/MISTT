import XCTest
@testable import MISTTConversation

final class WakeHandoffTests: XCTestCase {
    func testRetainedCommandMayBeReplayed() {
        XCTAssertTrue(WakeHandoff.canReplay(end: 16000, captured: 32000, oldest: 0))
        XCTAssertTrue(WakeHandoff.canReplay(end: 16000, captured: 16000, oldest: 16000))
    }
    func testExpiredOrUncertainCommandRequiresFreshCapture() {
        XCTAssertFalse(WakeHandoff.canReplay(end: 26880, captured: 82990, oldest: 51119))
        XCTAssertFalse(WakeHandoff.canReplay(end: 32001, captured: 32000, oldest: 0))
        XCTAssertFalse(WakeHandoff.canReplay(end: 0, captured: 0, oldest: nil))
    }
}
