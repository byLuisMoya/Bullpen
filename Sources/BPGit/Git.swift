import Foundation

public struct GitError: Error, LocalizedError, Equatable {
    public var arguments: [String]
    public var status: Int32
    public var stderr: String

    public var errorDescription: String? {
        "git \(arguments.joined(separator: " ")) failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Thin wrapper over the `git` command line (PLAN §4.2: libgit2 does not cover worktrees well).
public struct Git: Sendable {
    public var executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executable = executable
    }

    /// Runs git in `directory` and returns stdout. Throws `GitError` on a non-zero exit.
    @discardableResult
    public func run(_ arguments: [String], in directory: URL) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"  // never block on credential prompts
        env["LC_ALL"] = "C"               // stable, parseable output
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdoutTask = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
        let stderrTask = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // Unblock the reader tasks: nobody else will ever close these write ends.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        // Pipes are drained concurrently with the process so large outputs never fill the buffer.
        let stdout = String(decoding: await stdoutTask.value, as: UTF8.self)
        guard status == 0 else {
            throw GitError(arguments: arguments, status: status, stderr: String(decoding: await stderrTask.value, as: UTF8.self))
        }
        return stdout
    }
}
