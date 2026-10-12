import AppKit
import BPAgents
import BPCore
import BPSessions
import BPWorkspace
import Foundation

/// Things that were only commands (make demo, bp …) available as buttons.
enum AppActions {
    // MARK: Demo

    static var demoScript: URL? { Bundle.main.url(forResource: "demo", withExtension: "sh") }
    static var isDemoLoaded: Bool { FileManager.default.fileExists(atPath: "/tmp/bullpen-demo/ids") }

    /// Runs the bundled demo script (`start` or `stop`); returns its output on failure.
    static func demo(_ action: String) async throws {
        guard let script = demoScript, let macOS = Bundle.main.executableURL?.deletingLastPathComponent() else {
            throw SessionError(message: "La demo solo está disponible en la app empaquetada (make app).")
        }
        let result = await run("/bin/bash", [script.path, action], env: ["BULLPEN_APP_MACOS": macOS.path])
        if result.status != 0 { throw SessionError(message: "La demo falló: \(result.output.suffix(400))") }
    }

    // MARK: Command line

    /// `~/.local/bin/bp` → the bp inside this app. ~/.local/bin is a common PATH entry (Claude Code uses it).
    static func installCLI() throws -> String {
        guard let bp = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bp") else {
            throw SessionError(message: "No encuentro bp en la app.")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("bp")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bp)
        let inPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { String($0) == dir.path }
        return inPath ? "Instalado en \(link.path)." : "Instalado en \(link.path). Añade ~/.local/bin a tu PATH si `bp` no se encuentra."
    }

    static var mcpCommand: String {
        let bp = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bp").path ?? "bp"
        return "claude mcp add bullpen -- \(shellQuote(bp)) mcp"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Worktree

    static func openInTerminal(_ worktree: Worktree) {
        NSWorkspace.shared.open([URL(fileURLWithPath: worktree.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func run(_ executable: String, _ args: [String], env: [String: String] = [:]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            process.terminationHandler = { p in
                Task { continuation.resume(returning: (p.terminationStatus, String(decoding: await output.value, as: UTF8.self))) }
            }
            do { try process.run() } catch {
                try? pipe.fileHandleForWriting.close()
                continuation.resume(returning: (127, error.localizedDescription))
            }
        }
    }
}
