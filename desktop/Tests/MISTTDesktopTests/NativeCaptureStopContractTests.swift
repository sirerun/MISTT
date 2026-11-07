import Foundation
import XCTest
@testable import MISTTDesktop

final class NativeCaptureStopContractTests: XCTestCase {
    private final class DeferredTeardown: @unchecked Sendable {
        let lock = NSLock()
        var callback: (@Sendable (CaptureSnapshot) -> Void)?
        func begin(_ callback: @escaping @Sendable (CaptureSnapshot) -> Void) {
            lock.lock(); self.callback = callback; lock.unlock()
        }
        func complete(_ snapshot: CaptureSnapshot) {
            lock.lock(); let callback = self.callback; self.callback = nil; lock.unlock()
            callback?(snapshot)
        }
        var pending: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    }

    @MainActor
    func testDelayedTeardownCannotCompleteControlOrReportLateCallbackUnexpected() async throws {
        let teardown = DeferredTeardown()
        var busy = true
        var capturePresent = true
        var completed = false
        let task = Task { @MainActor in
            let snapshot = await NativeCaptureStopContract.waitForTeardown(teardown.begin)
            XCTAssertTrue(NativeCaptureStopContract.confirmed(snapshot))
            capturePresent = false
            busy = false
            completed = true
        }
        while !teardown.pending { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(busy)
        XCTAssertFalse(completed)
        XCTAssertFalse(NativeCaptureStopContract.isUnexpected(generationMatches: true, capturePresent: capturePresent, busy: busy))
        var snapshot = CaptureSnapshot(status: "synthetic closed", target: "synthetic")
        snapshot.microphoneIOStopped = true; snapshot.tapIOStopped = true
        snapshot.aggregateDestroyed = true; snapshot.tapDestroyed = true
        teardown.complete(snapshot)
        await task.value
        XCTAssertTrue(completed)
        XCTAssertFalse(NativeCaptureStopContract.isUnexpected(generationMatches: true, capturePresent: capturePresent, busy: busy))
    }

    func testMissingOrUnconfirmedTeardownIsNeverClosureProof() {
        var snapshot = CaptureSnapshot(status: "synthetic pending", target: "synthetic")
        XCTAssertFalse(NativeCaptureStopContract.confirmed(snapshot))
        snapshot.microphoneIOStopped = true; snapshot.tapIOStopped = true
        snapshot.aggregateDestroyed = true; snapshot.tapDestroyed = false
        XCTAssertFalse(NativeCaptureStopContract.confirmed(snapshot))
        XCTAssertFalse(NativeCaptureStopContract.isUnexpected(generationMatches: false, capturePresent: true, busy: false))
    }
    func testStopJoinersDuringPendingStartEachReceiveTeardownProof() throws {
        let capture = NativePairCapture(generation: 1)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let completions = expectation(description: "both stop callers receive proof")
        completions.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            defer { finished.signal() }
            try? capture.start(targets: [], validateTargets: {
                entered.signal()
                _ = release.wait(timeout: .now() + 0.5)
                return [] // Empty target prevents HAL creation after cancellation.
            }, generation: 1, onStop: { _ in })
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        for _ in 0..<2 {
            capture.stop(deadline: 1, onTeardown: { snapshot in
                XCTAssertTrue(NativeCaptureStopContract.confirmed(snapshot))
                completions.fulfill()
            })
        }
        release.signal()
        wait(for: [completions], timeout: 1)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 1.1) // Both joined deadlines must not consume the one completion twice.
    }

    func testUnconfirmedStartupStopDeadlineTerminatesIsolatedProcess() throws {
        if ProcessInfo.processInfo.environment["MISTT_TEST_STALLED_START"] == "1" {
            let capture = NativePairCapture(generation: 1)
            let entered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                try? capture.start(targets: [], validateTargets: {
                    entered.signal()
                    Thread.sleep(forTimeInterval: 2)
                    return []
                }, generation: 1, onStop: { _ in })
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            capture.stop(deadline: 0.05, onTeardown: { _ in })
            Thread.sleep(forTimeInterval: 1)
            XCTFail("unconfirmed teardown failed to terminate at its deadline")
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "MISTTDesktopTests.NativeCaptureStopContractTests/testUnconfirmedStartupStopDeadlineTerminatesIsolatedProcess", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MISTT_TEST_STALLED_START"] = "1"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let exited = expectation(description: "deadline fixture exits")
        child.terminationHandler = { _ in exited.fulfill() }
        wait(for: [exited], timeout: 3)
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 70)
    }

}
