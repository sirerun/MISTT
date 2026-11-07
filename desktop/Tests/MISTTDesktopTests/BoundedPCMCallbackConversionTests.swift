import Foundation
import NativeAudioQueue
import XCTest
@testable import MISTTDesktop

final class BoundedPCMCallbackConversionTests: XCTestCase {
    func testLargeStereoCallbacksMatchPersistentBoundedReference() throws {
        for frames in [4606, 4800, 8192] {
            let samples = (0..<frames).flatMap { frame -> [Float] in
                [Float(frame % 97) / 200 - 0.2, Float(frame % 71) / 300 - 0.1]
            }
            let actual = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 2)
            let reference = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 2)
            XCTAssertEqual(actual.maximumInputFrames, 4096)
            var output = try actual.appendCallbackInterleavedFloat(samples, channels: 2)
            var expected: [UInt8] = []
            for start in stride(from: 0, to: frames, by: 4096) {
                expected += try reference.appendInterleavedFloat(Array(samples[(start * 2)..<(min(start + 4096, frames) * 2)]), channels: 2)
            }
            output += try actual.finish()
            expected += try reference.finish()
            XCTAssertEqual(output, expected, "stereo frame/channel ordering for \(frames)")
            XCTAssertEqual(output.count / 2, [4606: 1535, 4800: 1600, 8192: 2731][frames]!)
            XCTAssertEqual(actual.inputFrameCount, UInt64(frames))
            XCTAssertEqual(actual.outputFrameCount, UInt64(output.count / 2))
        }
    }

    func testConsecutiveCallbacksKeepOneConverterAndMonoOrder() throws {
        let converter = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 1)
        let reference = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 1)
        var actual: [UInt8] = []
        var expected: [UInt8] = []
        for frames in [4606, 4800, 8192] {
            let samples = (0..<frames).map { Float($0 % 101) / 250 - 0.2 }
            actual += try converter.appendCallbackInterleavedFloat(samples, channels: 1)
            for start in stride(from: 0, to: frames, by: 4096) {
                expected += try reference.appendMonoFloat(Array(samples[start..<min(start + 4096, frames)]))
            }
        }
        actual += try converter.finish()
        expected += try reference.finish()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(converter.inputFrameCount, 17_598)
        XCTAssertEqual(actual.count / 2, 5866)
    }

    func testOversizedCallbackIsRejectedBeforeConverterOrQueueConsumesIt() throws {
        let converter = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 2)
        XCTAssertThrowsError(try converter.appendCallbackInterleavedFloat([Float](repeating: 0, count: 8193 * 2), channels: 2)) {
            XCTAssertEqual($0 as? PCMStreamConverterError, .inputBlockTooLarge)
        }
        XCTAssertEqual(converter.inputFrameCount, 0)
        XCTAssertThrowsError(try converter.appendCallbackInterleavedFloat([0, 1, 2], channels: 2))
        let queue = try XCTUnwrap(MISTTAudioQueueCreate(4, 8192))
        defer { MISTTAudioQueueDestroy(queue) }
        MISTTAudioQueueOpenGate(queue, 1)
        let oversized = [Float](repeating: 0, count: 8193)
        XCTAssertFalse(oversized.withUnsafeBufferPointer {
            MISTTAudioQueuePushFloat32(queue, $0.baseAddress, nil, 8193, 1, 48_000, 1)
        })
        XCTAssertEqual(MISTTAudioQueuePendingFrames(queue), 0)
    }
    func testFinishBoundsRetainOnlyActualFractionalOutputAndTrimPadding() {
        XCTAssertEqual(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4606, sourceRate: 16_000, targetRate: 16_000, emittedFrames: 0, pendingFrames: 4606), 4606)
        XCTAssertEqual(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4606, sourceRate: 48_000, targetRate: 16_000, emittedFrames: 1517, pendingFrames: 18), 18)
        XCTAssertEqual(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4606, sourceRate: 48_000, targetRate: 16_000, emittedFrames: 1517, pendingFrames: 19), 19)
        XCTAssertNil(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4606, sourceRate: 48_000, targetRate: 16_000, emittedFrames: 1517, pendingFrames: 17))
        XCTAssertEqual(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4800, sourceRate: 48_000, targetRate: 16_000, emittedFrames: 1582, pendingFrames: 50), 18)
        XCTAssertNil(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4800, sourceRate: 48_000, targetRate: 16_000, emittedFrames: 1582, pendingFrames: 17))
        XCTAssertNil(PCMStreamOutputBounds.releaseFrames(receivedFrames: 4800, sourceRate: 48_000, targetRate: 16_000, emittedFrames: 1601, pendingFrames: 0))
        XCTAssertNil(PCMStreamOutputBounds.releaseFrames(receivedFrames: UInt64.max, sourceRate: 1, targetRate: 1, emittedFrames: 0, pendingFrames: 0))
        XCTAssertNil(PCMStreamOutputBounds.releaseFrames(receivedFrames: 1, sourceRate: .nan, targetRate: 16_000, emittedFrames: 0, pendingFrames: 1))
    }

    func testFractionalAndIntegralRatesFinishWithinExactRationalBounds() throws {
        for rate in [32_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for channels in [1, 2] {
                let converter = try BoundedPCMStreamConverter(sourceRate: rate, channels: channels)
                let frames = 4606
                var bytes = try converter.appendCallbackInterleavedFloat([Float](repeating: 0.1, count: frames * channels), channels: channels)
                bytes += try converter.finish()
                let exact = Double(frames) * 16_000 / rate
                XCTAssertGreaterThanOrEqual(bytes.count / 2, Int(floor(exact)))
                XCTAssertLessThanOrEqual(bytes.count / 2, Int(ceil(exact)))
                XCTAssertEqual(converter.inputFrameCount, UInt64(frames))
                XCTAssertEqual(converter.outputFrameCount, UInt64(bytes.count / 2))
            }
        }
    }

}
