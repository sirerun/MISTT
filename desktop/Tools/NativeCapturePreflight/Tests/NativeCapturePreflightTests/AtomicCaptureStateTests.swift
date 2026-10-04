import XCTest
import PreflightAtomics
import Dispatch

private final class InterleaveBarrier {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
}

private let pauseBeforeCommit: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
    guard let raw else { return }
    let barrier = Unmanaged<InterleaveBarrier>.fromOpaque(raw).takeUnretainedValue()
    barrier.entered.signal()
    barrier.proceed.wait()
}

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

    func testSequentialOverlapFailsClosedButAllowsOneNanosecondQuantization() {
        let accepted = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(accepted) }
        let epoch: UInt64 = 10_000_000
        let firstStart: UInt64 = 10_100_000
        let previousDuration: UInt64 = 62_500 // exact 3-frame duration at 48 kHz
        MISTTOpenCaptureGate(accepted, epoch)
        XCTAssertEqual(MISTTRecordBuffer(accepted, 0, true, firstStart, 3, 48_000), 0)
        XCTAssertEqual(MISTTRecordBuffer(accepted, 0, true, firstStart + previousDuration - 1, 3, 48_000), 0)
        XCTAssertEqual(MISTTRecordBuffer(accepted, 0, true, firstStart + 2 * previousDuration - 1, 3, 48_000), 0)
        XCTAssertTrue(MISTTCaptureGateIsOpen(accepted))
        XCTAssertEqual(MISTTRecordBuffer(accepted, 0, true, firstStart + 3 * previousDuration - 2, 3, 48_000),
                       Int32(MISTT_FAILURE_BUFFER_OVERLAP))
        XCTAssertFalse(MISTTCaptureGateIsOpen(accepted))
        var source = MISTTSourceSnapshot()
        MISTTReadSource(accepted, 0, &source)
        XCTAssertEqual(source.buffers, 3)
        XCTAssertEqual(source.frames, 9)
        XCTAssertEqual(source.clipped_or_dropped_frames, 3)
        XCTAssertEqual(source.maximum_anchor_gap_ns, 0)

        let rejected = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(rejected) }
        MISTTOpenCaptureGate(rejected, epoch)
        XCTAssertEqual(MISTTRecordBuffer(rejected, 0, true, firstStart, 3, 48_000), 0)
        XCTAssertEqual(MISTTRecordBuffer(rejected, 0, true, firstStart + previousDuration - 2, 3, 48_000),
                       Int32(MISTT_FAILURE_BUFFER_OVERLAP))
        XCTAssertFalse(MISTTCaptureGateIsOpen(rejected))
        XCTAssertEqual(MISTTFirstFailure(rejected), UInt32(MISTT_FAILURE_BUFFER_OVERLAP))
    }

    func testImplausibleSampleRatesAndUnboundedCallbackFramesFailClosed() {
        let cases: [(UInt64, Double)] = [
            (160, 7_999),
            (160, 384_001),
            (160, .nan),
            (160, .infinity),
            (1_048_577, 16_000),
        ]
        for (frameCount, sampleRate) in cases {
            let state = MISTTCreateCaptureState()!
            MISTTOpenCaptureGate(state, 1_000_000)
            XCTAssertEqual(MISTTRecordBuffer(state, 0, true, 1_001_000, frameCount, sampleRate),
                           Int32(MISTT_FAILURE_INVALID_BUFFER))
            XCTAssertFalse(MISTTCaptureGateIsOpen(state))
            XCTAssertEqual(MISTTFirstFailure(state), UInt32(MISTT_FAILURE_INVALID_BUFFER))
            MISTTDestroyCaptureState(state)
        }
    }

    func testTimestampAdditionOverflowFailsWithoutWrappingFrameAccounting() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        let epoch = UInt64.max - 100
        MISTTOpenCaptureGate(state, epoch)
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, epoch - 1, 2, 16_000),
                       Int32(MISTT_FAILURE_COUNTER_OVERFLOW))
        XCTAssertFalse(MISTTCaptureGateIsOpen(state))
        var source = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &source)
        XCTAssertEqual(source.buffers, 0)
        XCTAssertEqual(source.frames, 0)
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

    func testStopInterleavingReconcilesLastCallbackUsingNewCutoff() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000_000)
        let barrier = InterleaveBarrier()
        let context = Unmanaged.passUnretained(barrier).toOpaque()
        let recorded = expectation(description: "callback completes")
        DispatchQueue.global().async {
            _ = MISTTRecordBufferWithTestHook(state, 0, true, 1_004_000_000, 160, 16_000, pauseBeforeCommit, context)
            recorded.fulfill()
        }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 1), .success)

        let closed = expectation(description: "stop cutoff reconciled")
        DispatchQueue.global().async {
            MISTTCloseCaptureGate(state, 1_005_000_000)
            closed.fulfill()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while MISTTCaptureGateIsOpen(state) && DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(MISTTCaptureGateIsOpen(state))
        barrier.proceed.signal()
        wait(for: [recorded, closed], timeout: 2)

        var mic = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        XCTAssertEqual(mic.frames, 16)
        XCTAssertEqual(mic.clipped_or_dropped_frames, 144)
    }

    func testFractional16kCutoffRetainsOnlySampleAnchorsStrictlyBeforeStop() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000_000)
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, 1_000_000_000, 8, 16_000), 0)
        MISTTCloseCaptureGate(state, 1_000_093_750)
        var mic = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        XCTAssertEqual(mic.frames, 2)
        XCTAssertEqual(mic.clipped_or_dropped_frames, 6)
    }

    func testCutoffAt44000nsRetainsOneOfTwo16kAnchors() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000_000)
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, 1_000_000_000, 2, 16_000), 0)
        MISTTCloseCaptureGate(state, 1_000_044_000)
        var mic = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        XCTAssertEqual(mic.frames, 1)
        XCTAssertEqual(mic.clipped_or_dropped_frames, 1)
    }
    func testFractional48kCutoffExcludesSampleWhoseInstantFallsAfterStop() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1_000_000_000)
        XCTAssertEqual(MISTTRecordBuffer(state, 0, true, 1_000_000_000, 3, 48_000), 0)
        // Sample #2 is at 41,666.667 ns; cutoff 41,666 ns conservatively excludes it.
        MISTTCloseCaptureGate(state, 1_000_041_666)
        var mic = MISTTSourceSnapshot()
        MISTTReadSource(state, 0, &mic)
        XCTAssertEqual(mic.frames, 2)
        XCTAssertEqual(mic.clipped_or_dropped_frames, 1)
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

    func testEnergyHandoffIsBoundedAndKeepsOnlyScalarLevelsInMemory() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1)
        for index in 0..<300 {
            _ = MISTTEnqueueEnergy(state, 0, UInt64(index + 1), UInt64(index + 2), UInt16(index))
        }
        var batch = MISTTEnergyBatch()
        MISTTDrainEnergy(state, 0, &batch)
        XCTAssertEqual(batch.count, UInt32(MISTT_ENERGY_RING_CAPACITY))
        XCTAssertEqual(batch.overflow, 44)
        XCTAssertEqual(MISTTEnergyBatchLevel(&batch, 0), 0)
        XCTAssertEqual(MISTTEnergyBatchLevel(&batch, 255), 255)
    }

    func testEnergySummaryDropsBufferWhoseEndCrossesStopCutoff() {
        let state = MISTTCreateCaptureState()!
        defer { MISTTDestroyCaptureState(state) }
        MISTTOpenCaptureGate(state, 1)
        XCTAssertTrue(MISTTEnqueueEnergy(state, 0, 100, 200, 32_000))
        MISTTCloseCaptureGate(state, 150)
        var batch = MISTTEnergyBatch()
        MISTTDrainEnergy(state, 0, &batch)
        XCTAssertEqual(batch.count, 0)
    }
}
