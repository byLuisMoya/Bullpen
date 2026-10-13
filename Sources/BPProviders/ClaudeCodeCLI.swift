import Foundation

/// Bullpen's small jobs through the user's own Claude Code (`claude -p`), so they work with a
/// subscription and no API key. Run isolated: a throwaway folder, no tools, no MCP servers, no
/// hooks or customisations, nothing saved as a session.
public enum ClaudeCodeCLI {
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func arguments(_ request: CompletionRequest, model: String) -> [String] {
        var args = ["-p", "--model", model.isEmpty ? "haiku" : model, "--tools", "", "--strict-mcp-config",
                    "--safe-mode", "--no-session-persistence"]
        if let system = request.system { args += ["--system-prompt", system] }
        return args + [request.prompt]
    }

    public static func complete(_ request: CompletionRequest, model: String, timeout: TimeInterval = 90) async throws -> String {
        guard let claude = locate() else { throw ProviderError("No se encuentra Claude Code (claude).") }
        let args = arguments(request, model: model)
        return try await Task.detached {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bullpen-claude-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let process = Process()
            process.executableURL = claude
            process.arguments = args
            process.currentDirectoryURL = dir
            // Not a nested session of whatever launched Bullpen.
            process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "BULLPEN_SESSION_ID")
            }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let timer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !text.isEmpty else {
                let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ProviderError("Claude Code falló (\(process.terminationStatus)): \(message.prefix(200))")
            }
            return text
        }.value
    }
}
