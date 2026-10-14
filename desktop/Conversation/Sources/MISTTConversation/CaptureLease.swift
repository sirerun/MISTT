import Darwin
import Foundation

/// Cooperative cross-process arbitration shared by legacy paired and microphone
/// capture. A crashed owner releases the OS lock; the inode is never unlinked.
public final class CaptureLease: @unchecked Sendable {
    private let descriptor: Int32
    public static func acquire() throws -> CaptureLease {
        let path = "/tmp/mistt-capture-\(getuid()).lock"
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MediaError.unavailable("cannot open MISTT capture ownership lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            close(fd); throw MediaError.unavailable("MISTT capture ownership lock is not private")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw MediaError.unavailable("MISTT microphone is busy with another paired or conversation session")
        }
        return CaptureLease(descriptor: fd)
    }
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
