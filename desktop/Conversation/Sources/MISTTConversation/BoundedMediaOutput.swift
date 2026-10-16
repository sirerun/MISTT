import Darwin
import Foundation

/// Owns nonblocking output away from the main actor. Admission includes the
/// currently written record; exhaustion or stalled output invalidates the stream.
public final class BoundedMediaOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.sirerun.mistt.media-output")
    private let descriptor: Int32
    private let capacity: Int
    private let timeout: TimeInterval
    private let onFailure: @Sendable () -> Void
    private var records: [Data] = []
    private var bytes = 0
    private var draining = false
    private var failed = false

    public init(fileHandle: FileHandle, capacity: Int = 1_048_576,
                timeout: TimeInterval = 1, onFailure: @escaping @Sendable () -> Void) throws {
        guard capacity > 0, timeout > 0, timeout.isFinite else { throw MediaError.invalidAudio }
        let fd = dup(fileHandle.fileDescriptor)
        guard fd >= 0 else { throw MediaError.unavailable("cannot duplicate output") }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            close(fd); throw MediaError.unavailable("cannot configure output")
        }
        descriptor = fd; self.capacity = capacity; self.timeout = timeout; self.onFailure = onFailure
    }

    deinit { close(descriptor) }

    public func enqueue(_ data: Data) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        guard data.count <= capacity - bytes else {
            failed = true; records.removeAll(); lock.unlock(); onFailure(); return
        }
        records.append(data); bytes += data.count
        let start = !draining; draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func fail() {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        failed = true; records.removeAll(); lock.unlock()
        onFailure()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !failed, !records.isEmpty else { draining = false; lock.unlock(); return }
            let data = records.removeFirst()
            lock.unlock()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var offset = 0
            while offset < data.count {
                lock.lock(); let stopped = failed; lock.unlock()
                if stopped { return }
                if ProcessInfo.processInfo.systemUptime >= deadline { fail(); return }
                let count = data.withUnsafeBytes { raw in
                    Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                }
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(1_000); continue }
                fail(); return
            }
            lock.lock(); bytes -= data.count; lock.unlock()
        }
    }
}
