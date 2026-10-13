import BPAgents
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
    /// Latest known state of every bpd session, refreshed by polling and by hook broadcasts.
    private(set) var infos: [String: SessionInfo] = [:]
    /// Agent hooks point at the `bp` executable that ships next to the app.
    let hooks: AgentHooks

    @ObservationIgnored private var client: SessionClient?
    @ObservationIgnored private var handlers: [String: WeakHandler] = [:]
    @ObservationIgnored private let log = Logger.bullpen("sessions")

    static func sessionID(for worktree: Worktree) -> String { "wt-\(worktree.id.uuidString)" }

    init() {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/usr/local/bin")
        hooks = AgentHooks.standard(bpPath: dir.appendingPathComponent("bp").path)
        do {
            try hooks.writeClaudeSettings()
        } catch {
            log.error("Cannot write Claude hook settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    func status(for worktree: Worktree) -> AgentStatus {
        let info = infos[Self.sessionID(for: worktree)]
        // A worktree from Orca whose terminal lives there: nothing to watch from here.
        if worktree.external, info == nil {
            return AgentStatus(state: .idle, detail: worktree.path.contains("/orca/") ? "abierto en Orca" : "creado fuera de Bullpen",
                               confidence: .low, since: nil)
        }
        return StatusEngine.status(for: info, profile: AgentProfile.named(worktree.agentProfileID))
    }

    /// Keeps `infos` fresh (foreground process and output activity are only visible through `list`).
    func startPolling() async {
        while !Task.isCancelled {
            if let client = try? await connection(), let sessions = try? await client.list() {
                infos = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    // MARK: Connection

    func connection() async throws -> SessionClient {
        if let client { return client }
        var client = try await connectOrLaunch()
        let hello = try await client.hello()
        if hello.build != Bullpen.version {
            let running = try await client.list().filter(\.isRunning).count
            if hello.protocolVersion >= 3 {
                // A daemon that can hand its terminals over: replace it without closing anything.
                log.info("Taking over from bpd \(hello.build, privacy: .public)")
                client.close()
                client = try await DaemonLauncher.takeOver(bpdPath: bpdPath, expectBuild: Bullpen.version)
                warning = nil
            } else if running == 0 {
                log.info("Replacing bpd \(hello.build, privacy: .public)")
                try? await client.shutdown()
                client.close()
                try await Task.sleep(for: .milliseconds(200))
                return try await connection()
            } else {
                // Too old to hand over: say so, and let the user choose when (closes those terminals).
                outdatedDaemon = (hello.build, running)
            }
        }
        self.client = client
        isConnected = true
        // Terminals that were open on a previous connection (e.g. before a takeover) follow along.
        for (id, handler) in handlers where handler.value != nil { try? await client.attach(id) }
        Task { [weak self] in
            for await event in client.events { self?.route(event) }
            self?.disconnected()
        }
        return client
    }

    private var bpdPath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bpd").path ?? "bpd"
    }

    private func connectOrLaunch() async throws -> SessionClient {
        try await DaemonLauncher.connect(bpdPath: bpdPath)
    }

    /// A bpd from before handovers existed, still running terminals: (its version, how many).
    private(set) var outdatedDaemon: (build: String, running: Int)?

    /// Restarts that old bpd so the current one runs; its terminals close (agents can be restarted).
    func restartOutdatedDaemon() async {
        guard let client else { return }
        try? await client.shutdown()
        client.close()
        disconnected()
        outdatedDaemon = nil
        try? await Task.sleep(for: .milliseconds(300))
        _ = try? await connection()
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
        case let .exited(id, status):
            infos[id]?.exitStatus = status
            handlers[id]?.value?.sessionExited(status: status)
        case let .activity(info):
            infos[info.id] = info
        default: break
        }
    }

    // MARK: Worktree shells

    /// The worktree's main tab: its running session, or a new one with its agent (Claude by
    /// default for worktrees made outside Bullpen), or a shell for terminal-only worktrees.
    func ensureMain(for worktree: Worktree, environment: [String: String] = [:], cols: UInt16 = 120, rows: UInt16 = 40) async throws -> String {
        let client = try await connection()
        let id = Self.sessionID(for: worktree)
        if let existing = try await client.list().first(where: { $0.id == id }) {
            // An Orca worktree opened before agents started by default has an empty shell as its
            // main terminal: swap it for the agent, but only while nothing is running in it.
            let idleShell = existing.command == nil
                && existing.foregroundProcess.map { StatusEngine.isShell($0) } ?? true
            let swap = worktree.external && worktree.agentProfileID == nil && idleShell && !(agentRunsElsewhere?(worktree) ?? false)
            if existing.isRunning, !swap { return id }
            if existing.isRunning {
                try? await client.kill(id, signal: SIGHUP)
                for _ in 0..<20 {
                    guard let session = try? await client.list().first(where: { $0.id == id }), session.isRunning else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try await client.remove(id)
        }
        var agentID = worktree.agentProfileID
        // Made in Orca or with git: it gets the main agent the first time it is opened here,
        // unless Orca already runs one there (two agents in one folder would step on each other).
        if agentID == nil, worktree.external, !(agentRunsElsewhere?(worktree) ?? false) {
            agentID = PrimaryAgent.id
            adoptAgent?(worktree, PrimaryAgent.id)
        }
        guard let profile = AgentProfile.named(agentID) else {
            return try await ensureShell(for: worktree, environment: environment, cols: cols, rows: rows)
        }
        hooks.prepare(profile, in: worktree.path)
        let launch = profile.launch(model: worktree.agentModel, prompt: nil, hooks: hooks)
        infos[id] = try await client.create(SessionSpec(id: id, cwd: worktree.path, command: launch.command,
                                                        environment: environment, cols: cols, rows: rows))
        return id
    }

    // MARK: Extra terminal tabs

    static func tabPrefix(for worktree: Worktree) -> String { sessionID(for: worktree) + "-t" }

    /// Whether another tool (Orca) has a live agent in this worktree (set by the app).
    @ObservationIgnored var agentRunsElsewhere: ((Worktree) -> Bool)?

    /// Saves the agent an outside worktree adopted (set by the app: the store owns the database).
    @ObservationIgnored var adoptAgent: ((Worktree, String) -> Void)?

    /// Extra terminals of a worktree (`wt-<id>-t2`, `-t3`…), in the order they were opened.
    func tabs(for worktree: Worktree) -> [String] {
        let prefix = Self.tabPrefix(for: worktree)
        return infos.keys.filter { $0.hasPrefix(prefix) }
            .sorted { (Int($0.dropFirst(prefix.count)) ?? 0) < (Int($1.dropFirst(prefix.count)) ?? 0) }
    }

    /// Opens one more terminal in the worktree's folder.
    func openTab(for worktree: Worktree, environment: [String: String] = [:]) async throws -> String {
        let client = try await connection()
        let prefix = Self.tabPrefix(for: worktree)
        let taken = try await client.list().compactMap { $0.id.hasPrefix(prefix) ? Int($0.id.dropFirst(prefix.count)) : nil }
        let id = prefix + String((taken.max() ?? 1) + 1)
        infos[id] = try await client.create(SessionSpec(id: id, cwd: worktree.path, environment: environment))
        return id
    }

    /// An extra tab's session, restarted as a shell if it ended.
    func ensureTab(_ id: String, for worktree: Worktree, environment: [String: String] = [:], cols: UInt16 = 120, rows: UInt16 = 40) async throws -> String {
        let client = try await connection()
        if let existing = try await client.list().first(where: { $0.id == id }) {
            if existing.isRunning { return id }
            try await client.remove(id)
        }
        infos[id] = try await client.create(SessionSpec(id: id, cwd: worktree.path, environment: environment, cols: cols, rows: rows))
        return id
    }

    func closeTab(_ id: String) async {
        guard let client = try? await connection() else { return }
        try? await client.kill(id, signal: SIGHUP)
        for _ in 0..<20 {
            guard let session = try? await client.list().first(where: { $0.id == id }), session.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await client.remove(id)
        infos[id] = nil
    }

    /// Returns the id of a running shell session for the worktree, starting one if needed.
    func ensureShell(for worktree: Worktree, environment: [String: String] = [:], cols: UInt16 = 120, rows: UInt16 = 40) async throws -> String {
        let client = try await connection()
        let id = Self.sessionID(for: worktree)
        if let existing = try await client.list().first(where: { $0.id == id }) {
            if existing.isRunning { return id }
            try await client.remove(id)
        }
        _ = try await client.create(SessionSpec(id: id, cwd: worktree.path, environment: environment, cols: cols, rows: rows))
        return id
    }

    /// Starts the worktree's terminal running `command` (an agent) instead of a plain shell.
    func startAgent(for worktree: Worktree, command: String, environment: [String: String] = [:]) async throws {
        let client = try await connection()
        let id = Self.sessionID(for: worktree)
        if let existing = try await client.list().first(where: { $0.id == id }) {
            guard !existing.isRunning else { throw SessionError(message: "El worktree ya tiene una terminal en marcha") }
            try await client.remove(id)
        }
        infos[id] = try await client.create(SessionSpec(id: id, cwd: worktree.path, command: command, environment: environment))
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

    /// Sends `text` to the worktree's agent as one message.
    func sendMessage(_ text: String, to worktree: Worktree) async throws {
        let client = try await connection()
        let id = Self.sessionID(for: worktree)
        guard try await client.list().contains(where: { $0.id == id && $0.isRunning }) else {
            throw SessionError(message: "El worktree no tiene una terminal en marcha")
        }
        try await client.sendMessage(id, text)
    }
    func resize(_ id: String, cols: Int, rows: Int) {
        client?.resize(id, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }

    func hasRunningSession(_ worktree: Worktree) async -> Bool {
        guard let sessions = try? await connection().list() else { return false }
        return sessions.contains { $0.id == Self.sessionID(for: worktree) && $0.isRunning }
    }

    /// Interrupts the agent (Ctrl-C, twice: most TUIs ask for a second one to quit).
    func interrupt(_ worktree: Worktree) {
        let id = Self.sessionID(for: worktree)
        client?.input(id, Data([0x03]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.client?.input(id, Data([0x03])) }
    }

    /// Closes the worktree's terminal and starts its agent again (no prompt; the conversation is new).
    func restartAgent(_ worktree: Worktree, environment: [String: String]) async throws {
        await close(worktree)
        guard let profile = AgentProfile.named(worktree.agentProfileID) else {
            _ = try await ensureShell(for: worktree, environment: environment)
            return
        }
        hooks.prepare(profile, in: worktree.path)
        let launch = profile.launch(model: worktree.agentModel, prompt: nil, hooks: hooks)
        try await startAgent(for: worktree, command: launch.command, environment: environment)
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
