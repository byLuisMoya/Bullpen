import BPCore
import BPSessions
import Darwin
import Foundation
import Observation
import os

/// Receives terminal bytes for one session.
@MainActor
protocol SessionOutputHandler: AnyObject {
    func sessionSnapshot(_ data: Data)
    func sessionOutput(_ data: Data)
    func sessionExited(status: Int32)
}

/// App side of the session daemon: starts `bpd` when needed and routes its events to terminal views.
@MainActor
@Observable
final class SessionManager {
    private(set) var isConnected = false
    /// Shown when a daemon from another version is still running sessions.
    private(set) var warning: String?

    @ObservationIgnored private var client: SessionClient?
    @ObservationIgnored private var handlers: [String: WeakHandler] = [:]
    @ObservationIgnored private let log = Logger.bullpen("sessions")

    static func sessionID(for worktree: Worktree) -> String { "wt-\(worktree.id.uuidString)" }

    // MARK: Connection

    func connection() async throws -> SessionClient {
        if let client { return client }
        let client = try await connectOrLaunch()
        let hello = try await client.hello()
        if hello.protocolVersion != SessionProtocol.version {
            if try await client.list().contains(where: \.isRunning) {
                warning = "Hay un bpd de otra versión (\(hello.build)) con sesiones activas; se reemplazará cuando terminen."
            } else {
                log.info("Replacing bpd \(hello.build, privacy: .public)")
                try? await client.shutdown()
                client.close()
                try await Task.sleep(for: .milliseconds(200))
                return try await connection()
            }
        }
        self.client = client
        isConnected = true
        Task { [weak self] in
            for await event in client.events { self?.route(event) }
            self?.disconnected()
        }
        return client
    }

    private func connectOrLaunch() async throws -> SessionClient {
        if let client = try? SessionClient.connect() { return client }
        try launchDaemon()
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let client = try? SessionClient.connect() { return client }
        }
        throw SessionError(message: "No se pudo arrancar bpd")
    }

    /// Starts `bpd` (next to the app executable) in its own session so it outlives the app.
    private func launchDaemon() throws {
        guard let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bpd").path,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw SessionError(message: "bpd no está junto a la app")
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let result = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        log.info("Launched bpd pid \(pid)")
        // Reap it if it exits while the app is running, so it never lingers as a zombie.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private func disconnected() {
        log.warning("bpd disconnected")
        client = nil
        isConnected = false
    }

    private func route(_ event: ServerMessage) {
        switch event {
        case let .snapshot(id, data): handlers[id]?.value?.sessionSnapshot(data)
        case let .output(id, data): handlers[id]?.value?.sessionOutput(data)
        case let .exited(id, status): handlers[id]?.value?.sessionExited(status: status)
        default: break
        }
    }

    // MARK: Worktree shells

    /// Returns the id of a running shell session for the worktree, starting one if needed.
    func ensureShell(for worktree: Worktree, cols: UInt16 = 120, rows: UInt16 = 40) async throws -> String {
        let client = try await connection()
        let id = Self.sessionID(for: worktree)
        if let existing = try await client.list().first(where: { $0.id == id }) {
            if existing.isRunning { return id }
            try await client.remove(id)
        }
        _ = try await client.create(SessionSpec(id: id, cwd: worktree.path, cols: cols, rows: rows))
        return id
    }

    func attach(_ id: String, handler: SessionOutputHandler) async throws {
        handlers[id] = WeakHandler(value: handler)
        try await connection().attach(id)
    }

    func detach(_ id: String, handler: SessionOutputHandler) {
        guard handlers[id]?.value === handler else { return }
        handlers[id] = nil
        client?.detach(id)
    }

    func input(_ id: String, _ data: Data) { client?.input(id, data) }
    func resize(_ id: String, cols: Int, rows: Int) {
        client?.resize(id, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }

    func hasRunningSession(_ worktree: Worktree) async -> Bool {
        guard let sessions = try? await connection().list() else { return false }
        return sessions.contains { $0.id == Self.sessionID(for: worktree) && $0.isRunning }
    }

    /// Hangs up the worktree's session (like closing its terminal window) and forgets it.
    func close(_ worktree: Worktree) async {
        guard let client = try? await connection() else { return }
        let id = Self.sessionID(for: worktree)
        try? await client.kill(id, signal: SIGHUP)
        for _ in 0..<20 {
            guard let session = try? await client.list().first(where: { $0.id == id }), session.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await client.remove(id)
    }
}

private struct WeakHandler {
    weak var value: SessionOutputHandler?
}
