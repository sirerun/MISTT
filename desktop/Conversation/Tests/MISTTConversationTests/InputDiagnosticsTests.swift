import XCTest
import Darwin
@testable import MISTTConversation
final class InputDiagnosticsTests: XCTestCase {
    @MainActor func testInputOnlyModeCannotAdmitConversation() async throws {
        let key = "ZATI_VOICE_DIAGNOSTIC_PLAIN_INPUT"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, "1", 1)
        let media = ConversationMedia()
        if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        do {
            try await media.start(sessionID: UUID().uuidString)
            XCTFail("Input-only diagnostics must never admit unprocessed conversation audio")
        } catch MediaError.unavailable(let reason) {
            XCTAssertEqual(reason, "Input-only diagnostics cannot start a conversation")
        }
    }
}
