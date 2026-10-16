import Foundation
import XCTest
@testable import MISTTConversation

final class OutputTests: XCTestCase {
    func testBlockedReaderFailsWithinDeadlineWithoutBlockingProducer() throws {
        let pipe = Pipe()
        let failed = expectation(description: "stalled output fails closed")
        failed.assertForOverFulfill = true
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting,
                                           capacity: 1_048_576, timeout: 0.5) { failed.fulfill() }
        let start = ProcessInfo.processInfo.systemUptime
        writer.enqueue(Data(repeating: 42, count: 512_000))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        wait(for: [failed], timeout: 2)
        withExtendedLifetime(writer) {}
    }

    func testQueueLimitFailsImmediatelyAndOnlyOnce() throws {
        let pipe = Pipe()
        let failed = expectation(description: "bounded admission fails")
        failed.assertForOverFulfill = true
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting,
                                           capacity: 8, timeout: 0.05) { failed.fulfill() }
        writer.enqueue(Data(repeating: 1, count: 9))
        writer.enqueue(Data(repeating: 1, count: 9))
        wait(for: [failed], timeout: 1)
    }

    func testOutputPreservesRecordOrder() throws {
        let pipe = Pipe()
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting) { XCTFail("output failed") }
        writer.enqueue(Data("first\n".utf8)); writer.enqueue(Data("second\n".utf8))
        var received = Data()
        while received.count < 13 {
            received.append(pipe.fileHandleForReading.availableData)
        }
        XCTAssertEqual(String(data: received, encoding: .utf8), "first\nsecond\n")
        withExtendedLifetime(writer) {}
    }

    func testFinishDrainsAcceptedRecordsBeforeCompletion() throws {
        let pipe = Pipe()
        let finished = expectation(description: "accepted output drained")
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting) { XCTFail("output failed") }
        writer.enqueue(Data("reply\nstopped\n".utf8))
        writer.finish { finished.fulfill() }
        writer.enqueue(Data("too late\n".utf8))
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8), "reply\nstopped\n")
    }

    func testFinishCannotReportSuccessWhenOutputStalls() throws {
        let pipe = Pipe()
        let failed = expectation(description: "stalled finish fails")
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting,
                                           timeout: 0.05) { failed.fulfill() }
        writer.enqueue(Data(repeating: 42, count: 512_000))
        writer.finish { XCTFail("stalled output must not report drained") }
        wait(for: [failed], timeout: 1)
        withExtendedLifetime(writer) {}
    }

    func testClosedReaderReportsFailureOnceWithoutSIGPIPE() throws {
        let pipe = Pipe()
        let failed = expectation(description: "closed output fails once")
        failed.assertForOverFulfill = true
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting) { failed.fulfill() }
        try pipe.fileHandleForReading.close()
        writer.enqueue(Data("event\n".utf8))
        wait(for: [failed], timeout: 1)
        writer.enqueue(Data("late\n".utf8))
        withExtendedLifetime(writer) {}
    }
}
