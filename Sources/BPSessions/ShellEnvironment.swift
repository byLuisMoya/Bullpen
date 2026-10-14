import Foundation

/// The PATH the user gets in a terminal window. Sessions run their command through
/// `$SHELL -l -c`, and a non-interactive zsh doesn't read `~/.zshrc`, where many installers
/// put their directory (`~/.local/bin` for Claude Code, nvm, Herd…). Without this, agents
/// that work in Terminal fail with "command not found".
public enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    /// PATH from an interactive login shell, resolved once (nil if the shell doesn't answer; a
    /// failure isn't kept, the next call tries again).
    public static var userPath: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let path = resolve()
        if let path { cached = path }
        return path
    }

    /// Looks `executable` up in `userPath`.
    public static func locate(_ executable: String) -> String? {
        if executable.contains("/") { return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil }
        let dirs = (userPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return dirs.map { "\($0)/\(executable)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let marker = "__BULLPEN_PATH__"

    private static func resolve() -> String? {
        // Markers around the value: rc files may print their own lines (greetings, warnings).
        let args = [loginShell(), "-i", "-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        // A session of its own, with no terminal: run from inside an agent's terminal (`bp`,
        // `bp mcp`), an interactive shell would otherwise take that terminal over and hang.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        let argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&pid, args[0], &actions, &attributes, argv, environ)
        close(fds[1])
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        guard spawned == 0 else { return nil }
        nonisolated(unsafe) var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = reader.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return nil
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Both PATHs in order, each directory once.
    public static func merge(_ paths: String?...) -> String? {
        var seen = Set<Substring>()
        let dirs = paths.compactMap { $0 }.flatMap { $0.split(separator: ":") }.filter { seen.insert($0).inserted }
        return dirs.isEmpty ? nil : dirs.joined(separator: ":")
    }

    static func parse(_ output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// `$SHELL`, or the account's shell when launched from Finder (GUI apps may not have `$SHELL`).
    public static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let value = String(cString: shell)
            if !value.isEmpty { return value }
        }
        return "/bin/zsh"
    }
}
