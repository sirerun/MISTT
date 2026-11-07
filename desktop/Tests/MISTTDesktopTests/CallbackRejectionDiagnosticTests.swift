import Foundation
import NativePairAtomics
import XCTest
@testable import MISTTDesktop

final class CallbackRejectionDiagnosticTests: XCTestCase {
    func testFirstRejectionIsCoherentAndDeliveredOnlyOnceWithoutChangingGate() throws {
        let state = try XCTUnwrap(MISTTCreateCaptureState())
        defer { MISTTDestroyCaptureState(state) }
        XCTAssertEqual(MISTTTakeCallbackRejection(state), 0)
        MISTTRecordCallbackRejection(state, 0, 7, 4606, 2, 0, 7)
        MISTTRecordCallbackRejection(state, 1, 1, 0, 0, 0, 0)
        XCTAssertEqual(CallbackRejectionDiagnostic.decode(MISTTTakeCallbackRejection(state)),
                       .init(code: 7, source: 0, flags: 7, channels: 2, buffers: 0, frames: 4606))
        XCTAssertEqual(MISTTTakeCallbackRejection(state), 0)
        MISTTRecordCallbackRejection(state, 1, 4, 8193, 2, 1, 0)
        XCTAssertEqual(MISTTTakeCallbackRejection(state), 0)
        XCTAssertEqual(MISTTFirstFailure(state), 0)
        XCTAssertFalse(MISTTCaptureGateIsOpen(state))
    }

    func testConcurrentRejectionsPublishOneCompleteSnapshot() throws {
        let state = try XCTUnwrap(MISTTCreateCaptureState())
        defer { MISTTDestroyCaptureState(state) }
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            MISTTRecordCallbackRejection(state, UInt32(index % 2), UInt32(index + 1),
                                        UInt32(index + 100), UInt32(index + 2), UInt32(index + 3), 7)
        }
        let diagnostic = try XCTUnwrap(CallbackRejectionDiagnostic.decode(MISTTTakeCallbackRejection(state)))
        let index = diagnostic.code - 1
        XCTAssertEqual(diagnostic.source, index % 2)
        XCTAssertEqual(diagnostic.frames, index + 100)
        XCTAssertEqual(diagnostic.channels, index + 2)
        XCTAssertEqual(diagnostic.buffers, index + 3)
        XCTAssertEqual(diagnostic.flags, 7)
        XCTAssertEqual(MISTTTakeCallbackRejection(state), 0)
    }

    func testNumericMetadataDoesNotOverflowPackedRecord() throws {
        let state = try XCTUnwrap(MISTTCreateCaptureState())
        defer { MISTTDestroyCaptureState(state) }
        MISTTRecordCallbackRejection(state, 1, 7, UInt32.max, UInt32.max, UInt32.max, UInt32.max)
        XCTAssertEqual(CallbackRejectionDiagnostic.decode(MISTTTakeCallbackRejection(state)),
                       .init(code: 7, source: 1, flags: 7, channels: 255, buffers: 255, frames: UInt32.max))
        XCTAssertNil(CallbackRejectionDiagnostic.decode(0))
        XCTAssertNil(CallbackRejectionDiagnostic.decode(UInt64.max))
    }
}
