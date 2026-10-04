import XCTest
import Darwin
@testable import NativeCapturePreflight

final class ControlPipeWatchdogTests: XCTestCase {
    func testEOFSignalsOwnerLossPromptly() throws {
        let lost = expectation(description: "pipe EOF reported")
        let watchdog = ControlPipeWatchdog(timeoutNanoseconds: 2_000_000_000) { reason in
            XCTAssertEqual(reason, .eof)
            lost.fulfill()
        }
        try watchdog.start()
        watchdog.closeControlChannel()
        wait(for: [lost], timeout: 1)
        watchdog.stop()
    }

    func testMonotonicHeartbeatDeadlineExpiresWithoutWallClockUse() throws {
        let lost = expectation(description: "monotonic deadline reported")
        let started = DispatchTime.now().uptimeNanoseconds
        let watchdog = ControlPipeWatchdog(timeoutNanoseconds: 300_000_000) { reason in
            XCTAssertEqual(reason, .heartbeatDeadline)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            XCTAssertLessThan(elapsed, 1_500_000_000)
            lost.fulfill()
        }
        try watchdog.start()
        wait(for: [lost], timeout: 1.5)
        watchdog.stop()
    }

    func testOwnedHelperExitClosesObservedOwnerPipe() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe()
        let output = Pipe()
        helper.standardInput = input
        helper.standardOutput = output
        try helper.run()
        output.fileHandleForWriting.closeFile()

        let lost = expectation(description: "owned helper EOF observed")
        let watchdog = ControlPipeWatchdog(timeoutNanoseconds: 2_000_000_000) { reason in
            XCTAssertEqual(reason, .eof)
            lost.fulfill()
        }
        try watchdog.start(reading: output.fileHandleForReading.fileDescriptor)
        try input.fileHandleForWriting.write(contentsOf: Data([0x48]))
        Thread.sleep(forTimeInterval: 0.1)
        helper.terminate()
        wait(for: [lost], timeout: 1)
        helper.waitUntilExit()
        watchdog.stop()
    }

    func testOwnedHelperStallExpiresMonotonicHeartbeatDeadline() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe()
        let output = Pipe()
        helper.standardInput = input
        helper.standardOutput = output
        try helper.run()
        output.fileHandleForWriting.closeFile()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
        }

        let lost = expectation(description: "stalled helper heartbeat expires")
        let watchdog = ControlPipeWatchdog(timeoutNanoseconds: 300_000_000) { reason in
            XCTAssertEqual(reason, .heartbeatDeadline)
            lost.fulfill()
        }
        try watchdog.start(reading: output.fileHandleForReading.fileDescriptor)
        wait(for: [lost], timeout: 1.5)
        watchdog.stop()
    }

    func testRepeatedStartIsRejectedAndDeinitClosesOwnedReader() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }

        let closed = expectation(description: "owned duplicate closed after deinit")
        var watchdog: ControlPipeWatchdog? = ControlPipeWatchdog(
            timeoutNanoseconds: 2_000_000_000,
            onReadDescriptorClosed: { closed.fulfill() },
            onLoss: { _ in }
        )
        try watchdog?.start(reading: descriptors[0])
        XCTAssertThrowsError(try watchdog?.start(reading: descriptors[0]))
        watchdog = nil
        wait(for: [closed], timeout: 1)
    }

    func testExternalReaderDoesNotChangeSharedPipeFlags() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }
        let flagsBefore = fcntl(descriptors[0], F_GETFL)
        XCTAssertGreaterThanOrEqual(flagsBefore, 0)

        let closed = expectation(description: "owned duplicate cancellation completed")
        let watchdog = ControlPipeWatchdog(
            timeoutNanoseconds: 2_000_000_000,
            onReadDescriptorClosed: { closed.fulfill() },
            onLoss: { _ in }
        )
        try watchdog.start(reading: descriptors[0])
        XCTAssertEqual(fcntl(descriptors[0], F_GETFL), flagsBefore)
        watchdog.stop()
        wait(for: [closed], timeout: 1)
    }

    func testHeartbeatAndStopSerializeWriterOwnership() throws {
        let closed = expectation(description: "writer-side EOF observed")
        let watchdog = ControlPipeWatchdog(timeoutNanoseconds: 2_000_000_000) { reason in
            XCTAssertEqual(reason, .eof)
            closed.fulfill()
        }
        try watchdog.start()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "watchdog-heartbeat-race", attributes: .concurrent)
        for _ in 0..<32 {
            group.enter()
            queue.async {
                for _ in 0..<100 { watchdog.sendHeartbeat() }
                group.leave()
            }
        }
        group.enter()
        queue.async {
            watchdog.closeControlChannel()
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        wait(for: [closed], timeout: 1)
        watchdog.stop()
        watchdog.sendHeartbeat()
    }
}
