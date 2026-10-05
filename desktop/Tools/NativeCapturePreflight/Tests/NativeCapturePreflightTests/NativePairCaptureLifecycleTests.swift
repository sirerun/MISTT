import XCTest
@testable import NativeCapturePreflight

@available(macOS 14.2, *)
final class NativePairCaptureLifecycleTests: XCTestCase {
    func testTeardownCompletionRunsWhenCaptureHasNoResources() {
        let finished = DispatchSemaphore(value: 0)
        let capture = NativePairCapture(generation: 1)

        capture.stop(onTeardown: { _ in finished.signal() })

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    }

    func testQueuedTeardownRetainsNativeCaptureUntilWorkCompletes() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var capture: NativePairCapture? = NativePairCapture(generation: 1)
        weak var weakCapture = capture

        capture?.enqueueStopQueueWork { owner in
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            withExtendedLifetime(owner) {}
            finished.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        capture = nil
        XCTAssertNotNil(weakCapture, "queued Core Audio teardown must retain its native owner")

        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        let deadline = Date().addingTimeInterval(1)
        while weakCapture != nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertNil(weakCapture, "the native owner may be released after teardown work returns")
    }

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
