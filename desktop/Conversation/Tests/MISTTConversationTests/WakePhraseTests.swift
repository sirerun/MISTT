import XCTest
@testable import MISTTConversation
final class WakePhraseTests: XCTestCase {
    func testWakePhraseAcrossRecognizerSegmentBoundaries() {
        XCTAssertEqual(WakePhraseMatcher.matches(["Hey", "Zati"]), [0...1])
        XCTAssertEqual(WakePhraseMatcher.matches(["Hey Zati"]), [0...0])
        XCTAssertEqual(WakePhraseMatcher.matches(["Hey,", "ZATI!"]), [0...1])
        XCTAssertEqual(WakePhraseMatcher.matches(["Well hey", "Zati can you hear me"]), [0...1])
        XCTAssertEqual(WakePhraseMatcher.matches(["Hey Zati", "hey", "Zati"]), [0...0, 1...2])
    }
    func testCloseNameSpellingsStillRequireHey() {
        for name in ["Zachi", "Zaty", "Zatti", "Zatee", "Zadi"] {
            XCTAssertEqual(WakePhraseMatcher.matches(["Hey", name]), [0...1])
            XCTAssertTrue(WakePhraseMatcher.matches([name]).isEmpty)
        }
    }
    func testUnrelatedAndNonadjacentWordsDoNotWake() {
        for words in [["Hey", "daddy"], ["Zati"], ["Hey", "everybody", "Zati"], ["Hey", "Zatitude"], ["They", "Zati"], []] {
            XCTAssertTrue(WakePhraseMatcher.matches(words).isEmpty)
        }
    }
}
