import XCTest
@testable import NativeCapturePreflight

final class ControlPipeWatchdogTests: XCTestCase {
    func testEOFSignalsOwnerLossPromptly() throws {
        let lost = expectation(description: "pipe EOF reported")
        let watchdog = ControlPipeWatchdog(timeoutNanoseconds: 2_000_000_000) { reason in
            XCTAssertEqual(reason, "control channel EOF")
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
            XCTAssertEqual(reason, "control heartbeat timed out")
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
            XCTAssertEqual(reason, "control channel EOF")
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
            XCTAssertEqual(reason, "control heartbeat timed out")
            lost.fulfill()
        }
        try watchdog.start(reading: output.fileHandleForReading.fileDescriptor)
        wait(for: [lost], timeout: 1.5)
        watchdog.stop()
    }
}
