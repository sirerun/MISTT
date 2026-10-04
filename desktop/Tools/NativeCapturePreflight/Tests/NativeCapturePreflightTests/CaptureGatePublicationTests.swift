import Foundation
import PreflightAtomics
import XCTest
@testable import NativeCapturePreflight

final class CaptureGatePublicationTests: XCTestCase {
    func testCutoffIsPublishedBeforeHeldLifecycleLockAndPassedUnchanged() {
        let fixture = CaptureStateFixture()
        let state = fixture.state
        let epoch: UInt64 = 1_000_000_000
        let cutoff = PairedCutoff(ticks: 1_005_000_000, clock: HostClock(epochTicks: epoch, convert: { $0 }))
        let lifecycle = HeldLifecycleLock()
        lifecycle.lock()
        var lifecycleLockHeld = true
        let worker = DispatchGroup()
        let events = CaptureGateEventRecorder()
        let gatePublished = DispatchSemaphore(value: 0)
        defer {
            if lifecycleLockHeld { lifecycle.unlock() }
            _ = worker.wait(timeout: .now() + 1)
        }

        MISTTOpenCaptureGate(state, epoch)
        XCTAssertTrue(MISTTCaptureGateIsOpen(state))
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, epoch, 160, 16_000), 0)

        worker.enter()
        DispatchQueue.global(qos: .userInitiated).async { [fixture] in
            defer { worker.leave() }
            CaptureGatePublication.publishBeforeLock(
                cutoff: cutoff,
                closeGate: { publishedCutoff in
                    MISTTCloseCaptureGate(fixture.state, publishedCutoff.nanoseconds)
                    events.record("gate", cutoff: publishedCutoff)
                    gatePublished.signal()
                },
                acquireLifecycleLock: {
                    lifecycle.lock()
                    events.record("lock", cutoff: nil)
                    lifecycle.unlock()
                }
            )
        }

        guard gatePublished.wait(timeout: .now() + 1) == .success else {
            XCTFail("C gate publication did not occur before the held lifecycle lock")
            return
        }
        XCTAssertFalse(MISTTCaptureGateIsOpen(state), "C gate must close while the lifecycle lock is still held")
        let beforeUnlock = events.snapshot()
        XCTAssertEqual(beforeUnlock.events, ["gate"])
        XCTAssertEqual(beforeUnlock.cutoff, cutoff)

        var beforePostCutoff = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &beforePostCutoff)
        XCTAssertEqual(beforePostCutoff.frames, 80, "the crossing buffer must be clipped at the shared cutoff")
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, cutoff.nanoseconds, 16, 16_000), 0)
        var afterPostCutoff = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &afterPostCutoff)
        XCTAssertEqual(afterPostCutoff.frames, beforePostCutoff.frames, "a post-cutoff buffer must retain no frames")

        lifecycle.unlock()
        lifecycleLockHeld = false
        guard worker.wait(timeout: .now() + 1) == .success else {
            XCTFail("lifecycle lock caller did not complete after lock release")
            return
        }
        let afterUnlock = events.snapshot()
        XCTAssertEqual(afterUnlock.events, ["gate", "lock"])
        XCTAssertEqual(afterUnlock.cutoff, cutoff)
    }
}

private final class CaptureStateFixture: @unchecked Sendable {
    let state = MISTTCreateCaptureState()!
    deinit { MISTTDestroyCaptureState(state) }
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
