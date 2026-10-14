import Darwin
import Foundation

enum UnixSocket {
    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Binds and listens on `path`. Fails with EADDRINUSE if a live daemon already answers there;
    /// a stale socket file from a dead daemon is replaced.
    static func listen(at path: String) throws -> (fd: Int32, inode: ino_t) {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let probe = try? connect(to: path) {
            close(probe)
            throw POSIXError(.EADDRINUSE)
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }
        var addr = try makeAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        chmod(path, 0o600)
        configure(fd)
        return (fd, inode(of: path) ?? 0)
    }

    static func inode(of path: String) -> ino_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_ino : nil
    }

    /// Removes the socket file only if it is still the one we created (a newer daemon may own the path now).
    static func unlinkIfOurs(_ path: String, inode: ino_t) {
        if self.inode(of: path) == inode { unlink(path) }
    }

    static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }
        var addr = try makeAddress(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }
        configure(fd)
        return fd
    }

    /// Close-on-exec (children must not inherit sockets), no SIGPIPE, non-blocking.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// Non-blocking, buffered writer for a socket or PTY fd, driven by a dispatch write source.
final class FDWriter {
    private let fd: Int32
    private let source: DispatchSourceWrite
    private var pending = Data()
    /// Bytes of `pending` already written: dropping them after every partial write would move
    /// the rest of the buffer each time (a big snapshot to a slow client, over and over).
    private var sent = 0
    private var resumed = false
    private(set) var failed = false
    let limit: Int

    init(fd: Int32, queue: DispatchQueue, limit: Int = 32 * 1_048_576) {
        self.fd = fd
        self.limit = limit
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
    }

    /// Queues bytes. Returns false if the peer is too slow (buffer over `limit`) or broken.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard !failed else { return false }
        pending.append(data)
        if pending.count - sent > limit {
            failed = true
            return false
        }
        flush()
        return !failed
    }

    private func flush() {
        while sent < pending.count {
            let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, $0.count - sent) }
            if n > 0 {
                sent += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                break
            } else {
                failed = true
                pending.removeAll()
                sent = 0
                break
            }
        }
        if sent == pending.count {
            pending.removeAll(keepingCapacity: pending.count <= 1_048_576)
            sent = 0
        } else if sent > 1_048_576, sent > pending.count / 2 {
            // Mostly written: drop that part once instead of on every write.
            pending.removeSubrange(pending.startIndex..<pending.startIndex + sent)
            sent = 0
        }
        if pending.isEmpty, resumed {
            source.suspend()
            resumed = false
        } else if !pending.isEmpty, !resumed {
            source.resume()
            resumed = true
        }
    }

    private var cancelled = false

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        // libdispatch traps when a suspended or never-activated source is released: resume before cancelling.
        if !resumed { source.resume() }
        source.cancel()
    }

    deinit { cancel() }
}

extension POSIXError {
    /// Error for the current `errno`.
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
