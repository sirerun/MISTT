import Darwin
import Foundation

/// A local pipe fixture for measuring paired teardown after EOF or a missed heartbeat.
/// The production Go/native IPC connection is not part of this preflight package.
final class ControlPipeWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sirerun.mistt.preflight.control-watchdog", qos: .userInitiated)
    private let lock = NSLock()
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
    private var finished = false
    private let timeoutNanoseconds: UInt64
    private let onLoss: @Sendable (String) -> Void

    init(timeoutNanoseconds: UInt64 = 2_000_000_000, onLoss: @escaping @Sendable (String) -> Void) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.onLoss = onLoss
    }

    func start() throws {
        var fileDescriptors: [Int32] = [0, 0]
        guard pipe(&fileDescriptors) == 0 else { throw POSIXError(.EIO) }
        readFD = fileDescriptors[0]
        writeFD = fileDescriptors[1]
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        lastHeartbeat = DispatchTime.now().uptimeNanoseconds

        let readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        readSource.setEventHandler { [weak self] in self?.receive() }
        readSource.setCancelHandler { [weak self] in self?.closeReadEnd() }
        source = readSource

        let heartbeatTimer = DispatchSource.makeTimerSource(queue: queue)
        heartbeatTimer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        heartbeatTimer.setEventHandler { [weak self] in self?.checkHeartbeat() }
        timer = heartbeatTimer
        readSource.resume()
        heartbeatTimer.resume()
    }

    func sendHeartbeat() {
        lock.lock(); let fd = writeFD; lock.unlock()
        guard fd >= 0 else { return }
        var byte: UInt8 = 0x48
        _ = withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }
    }

    func closeControlChannel() {
        lock.lock()
        let fd = writeFD
        writeFD = -1
        lock.unlock()
        if fd >= 0 { _ = Darwin.close(fd) }
    }

    func stop() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let source = self.source
        let timer = self.timer
        let writeFD = self.writeFD
        self.source = nil
        self.timer = nil
        self.writeFD = -1
        lock.unlock()
        timer?.cancel()
        source?.cancel()
        if writeFD >= 0 { _ = Darwin.close(writeFD) }
    }

    private func receive() {
        let fd = readFD
        guard fd >= 0 else { return }
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        if count == 0 {
            finish("control channel EOF")
        } else if count > 0 {
            lock.lock(); lastHeartbeat = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        }
    }

    private func checkHeartbeat() {
        lock.lock()
        let expired = DispatchTime.now().uptimeNanoseconds &- lastHeartbeat > timeoutNanoseconds
        lock.unlock()
        if expired { finish("control heartbeat timed out") }
    }

    private func finish(_ reason: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let source = self.source
        let timer = self.timer
        let writeFD = self.writeFD
        self.source = nil
        self.timer = nil
        self.writeFD = -1
        lock.unlock()
        timer?.cancel()
        source?.cancel()
        if writeFD >= 0 { _ = Darwin.close(writeFD) }
        onLoss(reason)
    }

    private func closeReadEnd() {
        lock.lock(); let fd = readFD; readFD = -1; lock.unlock()
        if fd >= 0 { _ = Darwin.close(fd) }
    }

    deinit { stop() }
}
