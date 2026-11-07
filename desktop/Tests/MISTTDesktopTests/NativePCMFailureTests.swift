import Foundation
import NativeAudioQueue
import XCTest
@testable import MISTTDesktop

final class NativePCMFailureTests: XCTestCase {
    func testPumpAndConverterErrorsHaveOnlyStaticDiagnosticClasses() {
        let pump: [(NativePCMStreamPump.PumpError, String)] = [
            (.alreadyDraining, "already_draining"), (.invalidBlock, "invalid_block"),
            (.invalidTimestamp, "invalid_timestamp"), (.formatChanged, "format_changed"),
            (.clockDiscontinuity, "clock_discontinuity"), (.writerRejectedAudio, "writer_rejected_audio"),
            (.sequenceOverflow, "sequence_overflow")
        ]
        for (error, expected) in pump { XCTAssertEqual(NativePCMStreamPump.failureClass(error), expected) }
        let converter: [(PCMStreamConverterError, String)] = [
            (.invalidFormat, "converter_invalid_format"), (.inputBlockTooLarge, "converter_input_block_too_large"),
            (.malformedInterleavedInput, "converter_malformed_input"), (.alreadyFinished, "converter_already_finished"),
            (.conversionFailed("private transcript token /file"), "converter_conversion_failed"),
            (.outputLimitExceeded, "converter_output_limit"), (.anchorOverflow, "converter_anchor_overflow")
        ]
        for (error, expected) in converter { XCTAssertEqual(NativePCMStreamPump.failureClass(error), expected) }
        XCTAssertEqual(NativePCMStreamPump.failureClass(NSError(domain: "private/path", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "private transcript token"])), "other")
    }

    func testQueueAcceptedLargeCallbackExceedsCurrentConverterDefault() throws {
        let count: UInt32 = 4800
        let queue = try XCTUnwrap(MISTTAudioQueueCreate(4, 8192))
        defer { MISTTAudioQueueDestroy(queue) }
        MISTTAudioQueueOpenGate(queue, 1)
        let samples = [Float](repeating: 0, count: Int(count))
        XCTAssertTrue(samples.withUnsafeBufferPointer {
            MISTTAudioQueuePushFloat32(queue, $0.baseAddress, nil, count, 1, 48_000, 1)
        })
        var left = [Float](repeating: 0, count: 8192)
        var right = left
        var block = MISTTAudioBlock()
        XCTAssertTrue(left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                MISTTAudioQueuePop(queue, l.baseAddress, r.baseAddress, 8192, &block)
            }
        })
        XCTAssertEqual(block.frame_count, count)
        let converter = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 1)
        XCTAssertThrowsError(try converter.appendMonoFloat(Array(left.prefix(Int(block.frame_count))))) {
            XCTAssertEqual($0 as? PCMStreamConverterError, .inputBlockTooLarge)
        }
    }
}
