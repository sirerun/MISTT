import XCTest
@testable import NativeCapturePreflight

@available(macOS 14.2, *)
final class NativePairCaptureLifecycleTests: XCTestCase {
    func testCancellationBeforeDetachedStartPreventsValidationAndCapture() throws {
        let capture = NativePairCapture(generation: 1)
        let cutoff = PairedCutoff(ticks: 12_000, clock: HostClock(epochTicks: 10_000, convert: { $0 * 10 }))
        capture.cancelStart(generation: 1, cutoff: cutoff)
        let stopped = expectation(description: "pre-cancelled generation reports muted")

        XCTAssertThrowsError(try capture.start(
            targets: [],
            validateTargets: { throw LifecycleTestError.validationShouldNotRun },
            generation: 1,
            onStop: { snapshot in
                XCTAssertTrue(snapshot.status.contains("start cancelled"))
                stopped.fulfill()
            }
        )) { error in
            guard let captureError = error as? CaptureStartError,
                  case .cancelled = captureError else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }

        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(capture.currentSnapshot().status, "Muted · start cancelled before native capture began")
    }
}

private enum LifecycleTestError: Error {
    case validationShouldNotRun
}
