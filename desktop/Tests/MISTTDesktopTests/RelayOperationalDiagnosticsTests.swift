import Foundation
import XCTest
@testable import MISTTDesktop

final class RelayOperationalDiagnosticsTests: XCTestCase {
    private let line = "2026/11/06 15:00:00 INFO paired_startup phase=native_start error_class=failure native_code=capture_start_failed elapsed_ms=42 session_id=00112233-4455-6677-8899-aabbccddeeff"

    func testStartupAllowsOnlyKnownFieldsAndEnums() {
        XCTAssertEqual(RelayOperationalDiagnostics.startupRecord(line),
                       .init(phase: "native_start", errorClass: "failure", nativeCode: "capture_start_failed", elapsedMS: 42))
        for bad in [line + " token=private", line.replacingOccurrences(of: "native_start", with: "private/path"),
                    line.replacingOccurrences(of: "failure", with: "private_transcript"),
                    line.replacingOccurrences(of: "capture_start_failed", with: "token=private"),
                    line.replacingOccurrences(of: "elapsed_ms=42", with: "elapsed_ms=private"),
                    line.replacingOccurrences(of: "00112233-4455-6677-8899-aabbccddeeff", with: "/private/file")] {
            XCTAssertNil(RelayOperationalDiagnostics.startupRecord(bad))
        }
    }

    func testStaticErrorsAndBridgeFailuresExcludePrivateSuffixes() {
        XCTAssertEqual(RelayOperationalDiagnostics.finalErrorClass("native owner disconnected"), "native_disconnected")
        XCTAssertNil(RelayOperationalDiagnostics.finalErrorClass("native owner disconnected token=private"))
        XCTAssertEqual(RelayOperationalDiagnostics.failureClass("MISTT relay heartbeat expired."), "heartbeat_expired")
        XCTAssertEqual(RelayOperationalDiagnostics.failureClass("private transcript /file token"), "other")
    }

    func testBoundedReaderRecoversAfterOversizeLineAndChunkBoundaries() {
        final class Received: @unchecked Sendable {
            var lines: [String] = []
        }
        let received = Received()
        let reader = RelayDiagnosticLineReader { received.lines.append($0) }
        reader.append(Data(repeating: 65, count: 4096))
        reader.append(Data("\nnative owner ".utf8))
        reader.append(Data("disconnected\n".utf8))
        XCTAssertEqual(received.lines, ["native owner disconnected"])
    }
}
