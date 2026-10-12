import Darwin
import Foundation

enum PTY {
    /// Starts `argv` on a new pseudo-terminal (as session leader with it as controlling tty,
    /// so Ctrl-C and job control work). Returns the child pid and the master fd.
    static func spawn(argv: [String], environment: [String: String], cwd: String, cols: UInt16, rows: UInt16) throws -> (pid: pid_t, master: Int32) {
        // Everything the child needs is prepared before fork: after fork only async-signal-safe calls are allowed.
        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cCwd = strdup(cwd)
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cCwd)
        }
        guard access(cArgv[0], X_OK) == 0 else { throw POSIXError(.ENOENT) }

        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = cArgv.withUnsafeBufferPointer { argvPtr in
            cEnv.withUnsafeBufferPointer { envPtr in
                let pid = forkpty(&master, nil, nil, &size)
                if pid == 0 {
                    // Ignored signals survive exec; give the child default dispositions and an empty mask.
                    for sig in [SIGPIPE, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGCHLD] { _ = signal(sig, SIG_DFL) }
                    var empty = sigset_t()
                    sigemptyset(&empty)
                    sigprocmask(SIG_SETMASK, &empty, nil)
                    _ = chdir(cCwd)
                    execve(argvPtr[0], argvPtr.baseAddress, envPtr.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EAGAIN) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        return (pid, master)
    }

    static func resize(master: Int32, cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Decodes a `waitpid` status: exit code, or 128 + signal number.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
