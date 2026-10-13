import Foundation

/// The PATH the user gets in a terminal window. Sessions run their command through
/// `$SHELL -l -c`, and a non-interactive zsh doesn't read `~/.zshrc`, where many installers
/// put their directory (`~/.local/bin` for Claude Code, nvm, Herd…). Without this, agents
/// that work in Terminal fail with "command not found".
public enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String??

    /// PATH from an interactive login shell, resolved once (nil if the shell doesn't answer).
    public static var userPath: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let path = resolve()
        cached = .some(path)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell())
        // Markers around the value: rc files may print their own lines (greetings, warnings).
        process.arguments = ["-i", "-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        guard (try? process.run()) != nil else { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        return parse(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
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
