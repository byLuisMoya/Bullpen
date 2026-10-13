import Darwin
import Foundation

public struct SetupReport: Equatable, Sendable {
    public var copied: [String] = []
    public var cloned: [String] = []
    /// Paths listed in the config that don't exist in the main checkout.
    public var missing: [String] = []
}

/// Prepares a fresh worktree from the main checkout (PLAN §6.1-6.2).
public enum WorktreeSetup {
    /// Copies `copy` files and clones `clone` folders that are absent from the worktree.
    /// APFS `clonefile` shares blocks until either side changes: `node_modules` appears instantly
    /// and takes no extra disk. Falls back to a normal copy on other file systems.
    public static func prepare(config: BullpenConfig, from source: URL, to worktree: URL) throws -> SetupReport {
        var report = SetupReport()
        for (paths, isClone) in [(config.copy, false), (config.clone, true)] {
            for path in paths {
                let from = source.appendingPathComponent(path), to = worktree.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: from.path) else { report.missing.append(path); continue }
                if FileManager.default.fileExists(atPath: to.path) { continue }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if clonefile(from.path, to.path, 0) != 0 {
                    try FileManager.default.copyItem(at: from, to: to)
                }
                if isClone { report.cloned.append(path) } else { report.copied.append(path) }
            }
        }
        return report
    }

    /// One shell line that runs the setup commands in order and then `then` (the agent) only if
    /// they all succeed; on failure it says so and leaves the user at a shell in the worktree.
    public static func command(setup: [String], then next: String?) -> String? {
        let setup = setup.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !setup.isEmpty else { return next }
        let steps = setup.joined(separator: " && ")
        let failure = "echo; echo \"\u{1B}[31m[bullpen] la preparación del worktree ha fallado\u{1B}[0m\"; exec \"$SHELL\" -l"
        return "{ \(steps); } || { \(failure); }; " + (next ?? "exec \"$SHELL\" -l")
    }

    /// A multi-line script as one setup step: run by the user's shell, stopping at the first
    /// failing line.
    public static func scriptStep(_ script: String?) -> String? {
        guard let script = script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else { return nil }
        return "\"$SHELL\" -ec '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Picks free TCP ports for `{{port:name}}`, avoiding ports already given to other worktrees.
public enum PortAllocator {
    public static func allocate(names: [String], taken: Set<Int>, range: ClosedRange<Int> = 4100...4999,
                                isFree: (Int) -> Bool = isPortFree) -> [String: Int] {
        var result: [String: Int] = [:]
        var used = taken
        var candidate = range.lowerBound
        for name in names {
            while candidate <= range.upperBound, used.contains(candidate) || !isFree(candidate) { candidate += 1 }
            guard candidate <= range.upperBound else { break }
            result[name] = candidate
            used.insert(candidate)
            candidate += 1
        }
        return result
    }

    /// True when nothing listens on 127.0.0.1:port right now.
    public static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

public struct CommandResult: Equatable, Sendable {
    public var command: String
    public var exitCode: Int32
    public var output: String
    public var succeeded: Bool { exitCode == 0 }

    public init(command: String, exitCode: Int32, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
    }
}

/// Runs config commands (teardown, verify) through the user's login shell, outside any terminal.
public enum CommandRunner {
    public static func run(_ commands: [String], in directory: URL, environment: [String: String],
                           timeout: TimeInterval = 600, stopOnFailure: Bool = true) async -> [CommandResult] {
        var results: [CommandResult] = []
        for command in commands {
            let result = await runOne(command, in: directory, environment: environment, timeout: timeout)
            results.append(result)
            if stopOnFailure && !result.succeeded { break }
        }
        return results
    }

    static func runOne(_ command: String, in directory: URL, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.currentDirectoryURL = directory
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let output = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            nonisolated(unsafe) let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { process in
                timer.cancel()
                Task {
                    let text = String(decoding: await output.value, as: UTF8.self)
                    continuation.resume(returning: CommandResult(command: command, exitCode: process.terminationStatus, output: text))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                try? pipe.fileHandleForWriting.close()
                continuation.resume(returning: CommandResult(command: command, exitCode: 127, output: error.localizedDescription))
            }
        }
    }
}
