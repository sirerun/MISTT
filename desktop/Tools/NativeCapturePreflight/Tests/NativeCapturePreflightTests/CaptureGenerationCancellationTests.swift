import XCTest
@testable import NativeCapturePreflight

final class CaptureGenerationCancellationTests: XCTestCase {
    func testCancelBeforeDetachedStartRemainsLatchedForThatGeneration() {
        let cancellation = CaptureGenerationCancellation()
        cancellation.cancel(through: 7)

        XCTAssertTrue(cancellation.isCancelled(7))
        XCTAssertTrue(cancellation.isCancelled(6))
        XCTAssertFalse(cancellation.isCancelled(8))
    }

    func testLaterGenerationIsNotCancelledByEarlierStop() {
        let cancellation = CaptureGenerationCancellation()
        cancellation.cancel(through: 7)

        XCTAssertFalse(cancellation.isCancelled(8))
        cancellation.cancel(through: 9)
        XCTAssertTrue(cancellation.isCancelled(9))
        XCTAssertFalse(cancellation.isCancelled(10))
    }
}
