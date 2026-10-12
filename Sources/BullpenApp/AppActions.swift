import AppKit
import BPAgents
import BPCore
import BPSessions
import BPWorkspace
import Foundation

/// Things that were only commands (make demo, bp …) available as buttons.
enum AppActions {
    // MARK: Demo

    /// Only local development builds (`make app` / `make run`) bundle the demo script;
    /// releases (`make release`) don't, so the demo never shows up in a downloaded app.
    static var demoScript: URL? { Bundle.main.url(forResource: "demo", withExtension: "sh") }
    static var demoAvailable: Bool { demoScript != nil }
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

/// Seasonal Dock icon (Halloween, Christmas). Only the Dock changes; the app bundle keeps its
/// regular icon so its code signature stays intact. BULLPEN_SEASON overrides the date (to preview).
@MainActor
enum SeasonalIcon {
    static func apply(now: Date = Date()) {
        let season = ProcessInfo.processInfo.environment["BULLPEN_SEASON"].flatMap(Season.init(rawValue:)) ?? Season.of(now)
        NSApp.applicationIconImage = season.iconResource
            .flatMap { Bundle.main.url(forResource: $0, withExtension: "png") }
            .flatMap(NSImage.init(contentsOf:))      // nil restores the bundle icon
    }

    /// Re-checks every hour so a long-running app switches on the first day of a season.
    static func keepUpdated() async {
        while !Task.isCancelled {
            apply()
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
