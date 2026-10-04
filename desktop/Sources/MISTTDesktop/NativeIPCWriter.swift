import Darwin
import Foundation

/// One nonblocking framed writer. Stop/control records outrank unstarted audio frames; source_end waits behind that source's frames.
final class NativeIPCWriter: @unchecked Sendable {
    enum Source: Hashable { case microphone, callAudio }
    enum Failure: Error { case queueFull, pipeClosed, writeFailed(Int32), invalidDescriptor }
    private struct PendingFrame { let data: Data; let source: Source?; let controlQueued: Bool }

    private let lock = NSLock()
    private let descriptor: Int32
    private let writeSource: DispatchSourceWrite
    private let callbackQueue = DispatchQueue(label: "com.sirerun.mistt.ipc-writer")
    private let onFailure: @Sendable (Failure) -> Void
    private var controls: [Data] = []
    private var microphone: [Data] = []
    private var callAudio: [Data] = []
    private var microphoneEnd: Data?
    private var callAudioEnd: Data?
    private var current: PendingFrame?
    private var offset = 0
    private var nextAudioIsMicrophone = true
    private var controlBytes = 0
    private var microphoneBytes = 0
    private var callAudioBytes = 0
    private var failed = false
    private var closed = false
    private var idleWaiters: [(Result<Void, Failure>) -> Void] = []

    init(fileHandle: FileHandle, onFailure: @escaping @Sendable (Failure) -> Void) throws {
        descriptor = fileHandle.fileDescriptor
        self.onFailure = onFailure
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.invalidDescriptor }
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: callbackQueue)
        writeSource.setEventHandler { [weak self] in self?.drive() }
        writeSource.setCancelHandler { fileHandle.closeFile() }
        writeSource.resume()
    }

    func enqueueControl<T: Encodable>(_ message: T) {
        do { try enqueueControlFrame(NativeControlFrame.encode(message)) }
        catch { fail(.queueFull) }
    }

    func enqueueControlFrame(_ frame: Data) throws {
        lock.lock()
        guard !failed, !closed else { lock.unlock(); throw Failure.pipeClosed }
        guard controls.count < 128, frame.count <= 1_048_576,
              controlBytes <= 1_048_576 - frame.count else {
            failed = true
            let waiters = idleWaiters; idleWaiters.removeAll()
            lock.unlock()
            onFailure(.queueFull)
            for waiter in waiters { waiter(.failure(.queueFull)) }
            throw Failure.queueFull
        }
        controls.append(frame)
        controlBytes += frame.count
        lock.unlock()
        drive()
    }

    func enqueueAudio(_ frame: Data, source: Source) -> Bool {
        lock.lock()
        guard !failed, !closed else { lock.unlock(); return false }
        let maximum = 32_768 // one second at 16 kHz mono s16le per source, plus framing margin
        if source == .microphone {
            guard microphoneBytes <= maximum - frame.count else { lock.unlock(); fail(.queueFull); return false }
            microphone.append(frame); microphoneBytes += frame.count
        } else {
            guard callAudioBytes <= maximum - frame.count else { lock.unlock(); fail(.queueFull); return false }
            callAudio.append(frame); callAudioBytes += frame.count
        }
        lock.unlock()
        drive()
        return true
    }

    func enqueueSourceEnd(_ message: SourceEnd, source: Source) {
        do {
            let frame = try NativeControlFrame.encode(message)
            lock.lock()
            guard !failed, !closed else { lock.unlock(); return }
            if source == .microphone { microphoneEnd = frame } else { callAudioEnd = frame }
            lock.unlock()
            drive()
        } catch { fail(.queueFull) }
    }

    func whenIdle(_ completion: @escaping (Result<Void, Failure>) -> Void) {
        lock.lock()
        if failed { lock.unlock(); completion(.failure(.pipeClosed)); return }
        if isIdleLocked { lock.unlock(); completion(.success(())); return }
        idleWaiters.append(completion)
        lock.unlock()
        drive()
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        writeSource.cancel()
    }

    private func drive() {
        lock.lock()
        guard !failed, !closed else { lock.unlock(); return }
        while true {
            if current == nil {
                current = selectNextLocked()
                offset = 0
            }
            guard let item = current else {
                let waiters = isIdleLocked ? idleWaiters : []
                if !waiters.isEmpty { idleWaiters.removeAll() }
                lock.unlock()
                for waiter in waiters { waiter(.success(())) }
                return
            }
            let result = item.data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), item.data.count - offset)
            }
            if result > 0 {
                offset += result
                if offset == item.data.count {
                    if let source = item.source {
                        if source == .microphone { microphoneBytes -= item.data.count }
                        else { callAudioBytes -= item.data.count }
                    } else if item.controlQueued {
                        controlBytes -= item.data.count
                    }
                    current = nil; offset = 0
                    continue
                }
                lock.unlock(); return
            }
            if result < 0 && errno == EINTR { continue }
            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { lock.unlock(); return }
            failed = true
            let error = result == 0 ? Failure.pipeClosed : Failure.writeFailed(errno)
            let waiters = idleWaiters
            idleWaiters.removeAll()
            lock.unlock()
            onFailure(error)
            for waiter in waiters { waiter(.failure(error)) }
            return
        }
    }

    private func selectNextLocked() -> PendingFrame? {
        if !controls.isEmpty { return PendingFrame(data: controls.removeFirst(), source: nil, controlQueued: true) }
        if nextAudioIsMicrophone, !microphone.isEmpty {
            nextAudioIsMicrophone = false
            return PendingFrame(data: microphone.removeFirst(), source: .microphone, controlQueued: false)
        }
        if !nextAudioIsMicrophone, !callAudio.isEmpty {
            nextAudioIsMicrophone = true
            return PendingFrame(data: callAudio.removeFirst(), source: .callAudio, controlQueued: false)
        }
        if !microphone.isEmpty { nextAudioIsMicrophone = false; return PendingFrame(data: microphone.removeFirst(), source: .microphone, controlQueued: false) }
        if !callAudio.isEmpty { nextAudioIsMicrophone = true; return PendingFrame(data: callAudio.removeFirst(), source: .callAudio, controlQueued: false) }
        if let end = microphoneEnd { microphoneEnd = nil; return PendingFrame(data: end, source: nil, controlQueued: false) }
        if let end = callAudioEnd { callAudioEnd = nil; return PendingFrame(data: end, source: nil, controlQueued: false) }
        return nil
    }

    private var isIdleLocked: Bool {
        current == nil && controls.isEmpty && microphone.isEmpty && callAudio.isEmpty &&
        microphoneEnd == nil && callAudioEnd == nil && controlBytes == 0 &&
        microphoneBytes == 0 && callAudioBytes == 0
    }

    private func fail(_ error: Failure) {
        lock.lock()
        guard !failed && !closed else { lock.unlock(); return }
        failed = true
        let waiters = idleWaiters; idleWaiters.removeAll()
        lock.unlock()
        onFailure(error)
        for waiter in waiters { waiter(.failure(error)) }
    }
}
