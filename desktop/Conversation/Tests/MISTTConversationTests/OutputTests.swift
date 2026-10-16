import Foundation
import XCTest
@testable import MISTTConversation

final class OutputTests: XCTestCase {
    func testBlockedReaderFailsWithinDeadlineWithoutBlockingProducer() throws {
        let pipe = Pipe()
        let failed = expectation(description: "stalled output fails closed")
        failed.assertForOverFulfill = true
        let writer = try BoundedMediaOutput(fileHandle: pipe.fileHandleForWriting,
                                           capacity: 1_048_576, timeout: 0.05) { failed.fulfill() }
        let start = ProcessInfo.processInfo.systemUptime
        writer.enqueue(Data(repeating: 42, count: 512_000))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.03)
        wait(for: [failed], timeout: 1)
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
}
