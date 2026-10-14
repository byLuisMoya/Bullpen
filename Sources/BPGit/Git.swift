import Foundation

public struct GitError: Error, LocalizedError, Equatable {
    public var arguments: [String]
    public var status: Int32
    public var stderr: String
    public var stdout: String = ""

    public var errorDescription: String? {
        "git \(arguments.joined(separator: " ")) failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Thin wrapper over the `git` command line (PLAN §4.2: libgit2 does not cover worktrees well).
public struct Git: Sendable {
    /// For polls of a working tree (status, diff): without it git may take index.lock to refresh
    /// the index, and an agent's own `git add`/`commit` at that moment would fail.
    public static let poll = ["GIT_OPTIONAL_LOCKS": "0"]

    public var executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executable = executable
    }

    /// Runs git in `directory` and returns stdout. Throws `GitError` on a non-zero exit.
    @discardableResult
    public func run(_ arguments: [String], in directory: URL, environment extra: [String: String] = [:]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"  // never block on credential prompts
        env["LC_ALL"] = "C"               // stable, parseable output
        env.merge(extra) { _, new in new }
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdoutTask = Self.readToEnd(out)
        let stderrTask = Self.readToEnd(err)

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
            throw GitError(arguments: arguments, status: status, stderr: String(decoding: await stderrTask.value, as: UTF8.self), stdout: stdout)
        }
        return stdout
    }

    /// Collects a pipe's output as it arrives, without blocking any thread while git runs (a
    /// blocking read would hold one for as long as the process lives: a slow push, many polls).
    private static func readToEnd(_ pipe: Pipe) -> Task<Data, Never> {
        let handle = pipe.fileHandleForReading
        let collected = Collected()
        return Task {
            await withCheckedContinuation { continuation in
                handle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        // End of file once: a late call after it must not resume again.
                        if let data = collected.finish() { continuation.resume(returning: data) }
                    } else {
                        collected.append(chunk)
                    }
                }
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finished = false
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        /// The output, the first time only.
        func finish() -> Data? {
            lock.withLock {
                guard !finished else { return nil }
                finished = true
                return data
            }
        }
    }
}
