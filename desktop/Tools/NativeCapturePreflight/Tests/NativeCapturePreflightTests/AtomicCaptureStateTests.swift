import XCTest
import PreflightAtomics

final class AtomicCaptureStateTests: XCTestCase {
    func testInvalidTimestampClosesSharedGateAndPreservesFirstFailure() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000)

        XCTAssertEqual(MISTTRecordBuffer(state, 0, false, 1_001_000, 160, 16_000), 1)
        XCTAssertFalse(MISTTCaptureGateIsOpen(state))
        XCTAssertEqual(MISTTFirstFailure(state), 1)
        XCTAssertEqual(MISTTRecordBuffer(state, 1, true, 1_002_000, 160, 16_000), 0)
        XCTAssertEqual(MISTTFirstFailure(state), 1)

        var mic = MISTTSourceSnapshot()
        var call = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        MISTTReadSource(state, 1, &call)
        XCTAssertEqual(mic.invalid_timestamps, 1)
        XCTAssertEqual(mic.frames, 0)
        XCTAssertEqual(call.frames, 0)
    }

    func testBackwardsAnchorFromEitherSourceFailsBothSourcesClosed() {
        for source: UInt32 in [0, 1] {
            let state = MISTTCreateCaptureState()!
            MISTTOpenCaptureGate(state, 10_000_000)
            XCTAssertEqual(MISTTRecordBuffer(state, source, true, 10_100_000, 160, 16_000), 0)
            XCTAssertEqual(MISTTRecordBuffer(state, source, true, 10_099_999, 160, 16_000), 2)
            XCTAssertFalse(MISTTCaptureGateIsOpen(state))
            XCTAssertEqual(MISTTFirstFailure(state), 2)
            MISTTDestroyCaptureState(state)
        }
    }

    func testCommonCutoffTrimsStraddlingBuffersAndRejectsLaterSamples() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000_000)
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, 1_000_000_000, 160, 16_000), 0)
        MISTTCloseCaptureGate(state, 1_005_000_000)
        XCTAssertFalse(MISTTCaptureGateIsOpen(state))
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, 1_004_000_000, 160, 16_000), 0)

        var mic = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        XCTAssertEqual(mic.frames, 80)
        XCTAssertEqual(mic.clipped_or_dropped_frames, 80)
    }

    func testDelayedPreOpenBufferIsTrimmedToNonnegativeSharedEpoch() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000_000)
        XCTAssertEqual(MISTTRecordBuffer(state, 1, true, 990_000_000, 320, 16_000), 0)
        var call = MISTTSourceSnapshot()
        MISTTReadSource(state, 1, &call)
        XCTAssertEqual(call.frames, 160)
        XCTAssertEqual(call.first_offset_ns, 0)
    }

    func testAtomicCallbackCountersCanBeReadConcurrentlyWithoutAudioHandoff() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 10_000_000_000)
        let group = DispatchGroup()
        for source: UInt32 in [0, 1] {
            group.enter()
            DispatchQueue.global().async {
                for index in 0..<1_000 {
                    _ = MISTTRecordBuffer(state, source, true, 10_000_000_000 + UInt64(index) * 10_000_000, 160, 16_000)
                }
                group.leave()
            }
        }
        for _ in 0..<100 {
            var mic = MISTTSourceSnapshot()
            var call = MISTTSourceSnapshot()
            MISTTReadSource(state, 0, &mic)
            MISTTReadSource(state, 1, &call)
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        var mic = MISTTSourceSnapshot()
        var call = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        MISTTReadSource(state, 1, &call)
        XCTAssertEqual(mic.buffers, 1_000)
        XCTAssertEqual(call.buffers, 1_000)
    }
}
