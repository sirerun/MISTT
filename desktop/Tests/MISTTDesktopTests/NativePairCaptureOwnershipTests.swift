import Foundation
import XCTest
@testable import MISTTDesktop

@available(macOS 14.2, *)
final class NativePairCaptureOwnershipTests: XCTestCase {
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
