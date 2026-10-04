import Foundation
import XCTest
@testable import NativeCapturePreflight

final class CaptureGatePublicationTests: XCTestCase {
    func testCutoffIsPublishedBeforeHeldLifecycleLockAndPassedUnchanged() {
        let lifecycle = HeldLifecycleLock()
        lifecycle.lock()
        let events = CaptureGateEventRecorder()
        let gatePublished = DispatchSemaphore(value: 0)
        let lockAcquired = DispatchSemaphore(value: 0)
        let cutoff = PairedCutoff(ticks: 24_000, clock: HostClock(epochTicks: 20_000, convert: { $0 * 5 }))

        DispatchQueue.global(qos: .userInitiated).async {
            CaptureGatePublication.publishBeforeLock(
                cutoff: cutoff,
                closeGate: { publishedCutoff in
                    events.record("gate", cutoff: publishedCutoff)
                    gatePublished.signal()
                },
                acquireLifecycleLock: {
                    lifecycle.lock()
                    events.record("lock", cutoff: nil)
                    lifecycle.unlock()
                    lockAcquired.signal()
                }
            )
        }

        XCTAssertEqual(gatePublished.wait(timeout: .now() + 1), .success)
        let beforeUnlock = events.snapshot()
        XCTAssertEqual(beforeUnlock.events, ["gate"])
        XCTAssertEqual(beforeUnlock.cutoff, cutoff)
        lifecycle.unlock()
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)
        let afterUnlock = events.snapshot()
        XCTAssertEqual(afterUnlock.events, ["gate", "lock"])
        XCTAssertEqual(afterUnlock.cutoff, cutoff)
    }
}

private final class HeldLifecycleLock: @unchecked Sendable {
    private let value = NSLock()
    func lock() { value.lock() }
    func unlock() { value.unlock() }
}

private final class CaptureGateEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var publishedCutoff: PairedCutoff?

    func record(_ event: String, cutoff: PairedCutoff?) {
        lock.lock()
        events.append(event)
        if let cutoff { publishedCutoff = cutoff }
        lock.unlock()
    }

    func snapshot() -> (events: [String], cutoff: PairedCutoff?) {
        lock.lock(); defer { lock.unlock() }
        return (events, publishedCutoff)
    }
}
