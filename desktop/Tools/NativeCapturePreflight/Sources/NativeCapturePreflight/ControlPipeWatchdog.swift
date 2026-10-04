import Darwin
import Foundation

final class ControlPipeWatchdog {
    enum Loss: Equatable { case eof, heartbeatDeadline }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.sirerun.mistt.preflight.pipe-watchdog")
    private let timeoutNanoseconds: UInt64
    private let onLoss: (Loss) -> Void
    private let onReadDescriptorClosed: () -> Void
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1
    private var started = false
    private var finished = false
    private var lastHeartbeat = DispatchTime.now().uptimeNanoseconds

    init(timeoutNanoseconds: UInt64 = 2_000_000_000, onReadDescriptorClosed: @escaping () -> Void = {}, onLoss: @escaping (Loss) -> Void) {
        self.timeoutNanoseconds = max(100_000_000, timeoutNanoseconds)
        self.onReadDescriptorClosed = onReadDescriptorClosed
        self.onLoss = onLoss
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureNotStartedLocked()

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        do {
            try setNonBlockingPrivateWriter(descriptors[1])
            installSourcesLocked(readDescriptor: descriptors[0], writeDescriptor: descriptors[1])
        } catch {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
            throw error
        }
    }

    /// Observes EOF/heartbeats from an externally owned writer without changing
    /// the caller's shared pipe status flags. The duplicated read descriptor is
    /// owned and closed by the dispatch source's cancellation handler.
    func start(reading descriptor: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureNotStartedLocked()
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        let ownedReadDescriptor = Darwin.dup(descriptor)
        guard ownedReadDescriptor >= 0 else { throw POSIXError(.EBADF) }
        do {
            installSourcesLocked(readDescriptor: ownedReadDescriptor, writeDescriptor: -1)
        } catch {
            _ = Darwin.close(ownedReadDescriptor)
            throw error
        }
    }

    /// A repeated start is an error. Callers must create a new watchdog after
    /// stopping so no abandoned descriptor/source can be replaced in place.
    private func ensureNotStartedLocked() throws {
        guard !started, !finished else { throw POSIXError(.EALREADY) }
    }

    private func setNonBlockingPrivateWriter(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { throw POSIXError(.EIO) }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(.EIO)
        }
    }

    private func installSourcesLocked(readDescriptor: Int32, writeDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.receive(from: readDescriptor) }
        let onReadDescriptorClosed = self.onReadDescriptorClosed
        source.setCancelHandler {
            _ = Darwin.close(readDescriptor)
            onReadDescriptorClosed()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkDeadline() }

        started = true
        readFD = readDescriptor
        writeFD = writeDescriptor
        lastHeartbeat = DispatchTime.now().uptimeNanoseconds
        readSource = source
        self.timer = timer
        source.resume()
        timer.resume()
    }

    func sendHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard started, !finished, writeFD >= 0 else { return }
        var byte: UInt8 = 0x48
        while write(writeFD, &byte, 1) < 0, errno == EINTR {}
        // EAGAIN means an earlier heartbeat is still queued and will keep the
        // reader alive until it drains; this call never blocks on a full pipe.
    }

    func closeControlChannel() {
        lock.lock()
        defer { lock.unlock() }
        guard writeFD >= 0 else { return }
        _ = Darwin.close(writeFD)
        writeFD = -1
    }

    func stop() {
        let source: DispatchSourceRead?
        let timer: DispatchSourceTimer?
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        source = readSource
        timer = self.timer
        readSource = nil
        self.timer = nil
        readFD = -1
        if writeFD >= 0 {
            _ = Darwin.close(writeFD)
            writeFD = -1
        }
        lock.unlock()
        timer?.cancel()
        source?.cancel()
    }

    deinit { stop() }

    private func receive(from descriptor: Int32) {
        var byte: UInt8 = 0
        let count = read(descriptor, &byte, 1)
        if count == 0 {
            finish(.eof)
        } else if count > 0 {
            lock.lock()
            if !finished { lastHeartbeat = DispatchTime.now().uptimeNanoseconds }
            lock.unlock()
        } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
            finish(.eof)
        }
    }

    private func checkDeadline() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let expired = !finished && now >= lastHeartbeat && now - lastHeartbeat > timeoutNanoseconds
        lock.unlock()
        if expired { finish(.heartbeatDeadline) }
    }

    private func finish(_ loss: Loss) {
        let source: DispatchSourceRead?
        let timer: DispatchSourceTimer?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        source = readSource
        timer = self.timer
        readSource = nil
        self.timer = nil
        readFD = -1
        if writeFD >= 0 {
            _ = Darwin.close(writeFD)
            writeFD = -1
        }
        lock.unlock()

        timer?.cancel()
        source?.cancel()
        onLoss(loss)
    }

}
