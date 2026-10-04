import XCTest
@testable import NativeCapturePreflight

final class HostClockTests: XCTestCase {
    func testNonUnitTickScaleConvertsEpochAnchorsAndCutoffBeforeComparison() {
        // Values mirror docs/contracts/fixtures/paired-v1.json's injected_clock_fixture.
        let clock = HostClock(epochTicks: 123_456, convert: { $0 * 1_000 })
        XCTAssertEqual(clock.epochNanoseconds, 123_456_000)
        XCTAssertEqual(clock.offsetNanoseconds(for: 123_481), 25_000)
        let stop = PairedCutoff(ticks: 123_500, clock: clock)
        XCTAssertEqual(stop.nanoseconds, 123_500_000)
    }

    func testCommonCutoffTrimsPrefixAndRejectsSamplesAtOrAfterStop() {
        let clock = HostClock(epochTicks: 0, convert: { $0 })
        let range = PairedCutoff.retainedRange(
            bufferStartNanoseconds: 0,
            frameCount: 10,
            sampleRate: 1_000_000_000,
            gateOpenNanoseconds: 2,
            stopNanoseconds: 8
        )
        XCTAssertEqual(range, 2..<8)
        XCTAssertEqual(PairedCutoff(ticks: 2, clock: clock).nanoseconds, 2)
    }

    func testPostCutoffBufferRetainsNoFramesAndPreCutoffBufferRetainsOnlyEarlierFrames() {
        XCTAssertEqual(
            PairedCutoff.retainedRange(
                bufferStartNanoseconds: 20,
                frameCount: 10,
                sampleRate: 1_000_000_000,
                gateOpenNanoseconds: 0,
                stopNanoseconds: 20
            ),
            0..<0
        )
        XCTAssertEqual(
            PairedCutoff.retainedRange(
                bufferStartNanoseconds: 0,
                frameCount: 10,
                sampleRate: 1_000_000_000,
                gateOpenNanoseconds: 0,
                stopNanoseconds: 5
            ),
            0..<5
        )
    }

    func testFractional16kSampleAnchorAt93750nsUsesEndExclusiveCeiling() {
        XCTAssertEqual(
            PairedCutoff.retainedRange(
                bufferStartNanoseconds: 0,
                frameCount: 8,
                sampleRate: 16_000,
                gateOpenNanoseconds: 0,
                stopNanoseconds: 93_750
            ),
            0..<2
        )
    }

    func testUnknownTargetMustNotFallBackToAnotherProcess() {
        let unrelated = AudioClient(objectID: 3, pid: 42, bundleID: "com.example.other", runningOutput: true)
        XCTAssertThrowsError(try CoreAudioInventory.resolveTargets(primaryBundleID: "com.tiktok.livestudio.desktop", from: [unrelated], validate: { _ in }))
    }

    func testDuplicateTargetProcessObjectsFailClosed() {
        let first = AudioClient(objectID: 3, pid: 42, bundleID: "com.tiktok.livestudio.desktop", runningOutput: true)
        let second = AudioClient(objectID: 4, pid: 43, bundleID: "com.tiktok.livestudio.desktop", runningOutput: true)
        XCTAssertThrowsError(try CoreAudioInventory.resolveTargets(primaryBundleID: "com.tiktok.livestudio.desktop", from: [first, second], validate: { _ in }))
    }

    func testSilentButLiveTargetObjectIsStillAccepted() throws {
        let target = AudioClient(objectID: 3, pid: getpid(), bundleID: "com.tiktok.livestudio.desktop", runningOutput: false)
        let result = try CoreAudioInventory.resolveTargets(
            primaryBundleID: "com.tiktok.livestudio.desktop",
            from: [target],
            validate: { _ in }
        )
        XCTAssertEqual(result, [target])
    }

    func testScalarPropertyReaderSupportsCoreAudioIntegerTypesWithoutHardware() throws {
        let expectedPID: pid_t = 64_321
        let actualPID: pid_t = try CoreAudioInventory.readScalarProperty("fixture PID") { value, size in
            XCTAssertEqual(size.pointee, UInt32(MemoryLayout<pid_t>.size))
            value.pointee = expectedPID
            return noErr
        }
        XCTAssertEqual(actualPID, expectedPID)

        let expectedRunning: UInt32 = 1
        let actualRunning: UInt32 = try CoreAudioInventory.readScalarProperty("fixture running flag") { value, size in
            XCTAssertEqual(size.pointee, UInt32(MemoryLayout<UInt32>.size))
            value.pointee = expectedRunning
            return noErr
        }
        XCTAssertEqual(actualRunning, expectedRunning)
    }
}
