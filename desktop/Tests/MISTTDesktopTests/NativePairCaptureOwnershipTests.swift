import Foundation
import XCTest
import MISTTConversation
@testable import MISTTDesktop

@available(macOS 14.2, *)
final class NativePairCaptureOwnershipTests: XCTestCase {
    func testRepeatedGenerationValidationRetainsSingleLease() throws {
        enum Probe: Error { case finished }
        let capture = NativePairCapture(generation: 42)
        var validated = false
        XCTAssertThrowsError(try capture.start(targets: [], validateTargets: {
            validated = true
            XCTAssertTrue(capture.isStartGenerationCurrent(42))
            XCTAssertTrue(capture.isStartGenerationCurrent(42))
            XCTAssertThrowsError(try CaptureLease.acquire())
            throw Probe.finished
        }, generation: 42, onStop: { _ in }))
        XCTAssertTrue(validated)
        let released = try CaptureLease.acquire()
        withExtendedLifetime(released) {}
    }

    func testTeardownCompletionRunsWhenCaptureHasNoResources() {
        let finished = DispatchSemaphore(value: 0)
        let capture = NativePairCapture(generation: 1)

        capture.stop(onTeardown: { snapshot in
            XCTAssertTrue(snapshot.microphoneIOStopped == true)
            XCTAssertTrue(snapshot.tapIOStopped == true)
            XCTAssertTrue(snapshot.tapCallbacksQuiesced == true)
            XCTAssertTrue(snapshot.aggregateDestroyed == true)
            XCTAssertTrue(snapshot.tapDestroyed == true)
            finished.signal()
        })

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
}
