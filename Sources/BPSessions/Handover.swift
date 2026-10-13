import Darwin
import Foundation

/// What an old bpd hands to its replacement: each session's state and recent output. The PTY
/// master descriptors follow on the same socket (SCM_RIGHTS), one per running session, in order.
struct HandoverPayload: Codable {
    struct Item: Codable {
        var info: SessionInfo
        var replay: Data
    }
    var build: String
    var sessions: [Item]
}

/// Passing file descriptors between processes over a Unix socket.
enum FDPassing {
    private static func align(_ n: Int) -> Int { (n + 3) & ~3 }   // Darwin aligns control data to 32 bits
    private static var headerSpace: Int { align(MemoryLayout<cmsghdr>.size) }
    private static var space: Int { headerSpace + align(MemoryLayout<Int32>.size) }

    /// Sends `fd` with one byte of payload.
    static func send(_ fd: Int32, over socket: Int32) -> Bool {
        var byte: UInt8 = 0x46
        var control = [UInt8](repeating: 0, count: space)
        return withUnsafeMutablePointer(to: &byte) { bytePtr in
            var iov = iovec(iov_base: bytePtr, iov_len: 1)
            return control.withUnsafeMutableBytes { ctl in
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    let cmsg = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                    cmsg.pointee.cmsg_level = SOL_SOCKET
                    cmsg.pointee.cmsg_type = SCM_RIGHTS
                    cmsg.pointee.cmsg_len = socklen_t(headerSpace + MemoryLayout<Int32>.size)
                    (ctl.baseAddress! + headerSpace).assumingMemoryBound(to: Int32.self).pointee = fd
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = ctl.baseAddress
                    msg.msg_controllen = socklen_t(space)
                    return sendmsg(socket, &msg, 0) == 1
                }
            }
        }
    }

    /// Receives one descriptor sent with `send`.
    static func receive(over socket: Int32) -> Int32? {
        var byte: UInt8 = 0
        var control = [UInt8](repeating: 0, count: space)
        return withUnsafeMutablePointer(to: &byte) { bytePtr in
            var iov = iovec(iov_base: bytePtr, iov_len: 1)
            return control.withUnsafeMutableBytes { ctl in
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = ctl.baseAddress
                    msg.msg_controllen = socklen_t(space)
                    guard recvmsg(socket, &msg, 0) == 1, msg.msg_controllen >= socklen_t(headerSpace + MemoryLayout<Int32>.size) else { return nil }
                    let cmsg = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                    guard cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS else { return nil }
                    return (ctl.baseAddress! + headerSpace).assumingMemoryBound(to: Int32.self).pointee
                }
            }
        }
    }

    /// Writes all of `data` on a blocking socket.
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// Reads exactly `count` bytes from a blocking socket.
    static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
        return ok ? data : nil
    }

    static func setBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    }
}
