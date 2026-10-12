import BPAgents
import BPCore
import BPEnv
import BPGit
import BPPersistence
import BPSessions
import Foundation
import os

public struct WorkspaceError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Everything needed to create a worktree (PLAN §6.1).
public struct WorktreeRequest: Sendable {
    public var project: Project
    public var branch: String
    public var baseRef: String
    public var agent: AgentProfile?
    public var model: String?
    public var task: String?
    public var globalPrompt: String?
    public var sendInitialPrompt: Bool
    public var runID: UUID?
    public var ticket: TicketRef?
    /// For agents that need their prompt typed in: wait for it (the CLI) or do it in the background (the app).
    public var awaitTypedPrompt = false

    public init(project: Project, branch: String, baseRef: String, agent: AgentProfile? = nil, model: String? = nil,
                task: String? = nil, globalPrompt: String? = nil, sendInitialPrompt: Bool = true) {
        self.project = project
        self.branch = branch
        self.baseRef = baseRef
        self.agent = agent
        self.model = model
        self.task = task
        self.globalPrompt = globalPrompt
        self.sendInitialPrompt = sendInitialPrompt
    }
}

/// Creating and removing worktrees end to end: git, `.bullpen.toml` (ports, copies, clones,
/// setup, teardown), the database, Claude's folder trust and the bpd session. Shared by the
/// app and the CLI so both behave the same.
public struct Workspace: Sendable {
    public var database: AppDatabase
    public var connect: @Sendable () async throws -> SessionClient
    public var hooks: AgentHooks
    public var worktreeRoot: URL
    /// nil skips Claude trust handling (tests).
    public var claudeTrust: ClaudeTrust?
    private let log = Logger(subsystem: "com.byluismoya.Bullpen", category: "workspace")

    public init(database: AppDatabase, connect: @escaping @Sendable () async throws -> SessionClient, hooks: AgentHooks,
                worktreeRoot: URL = WorktreeLocation.defaultRoot, claudeTrust: ClaudeTrust? = ClaudeTrust()) {
        self.database = database
        self.connect = connect
        self.hooks = hooks
        self.worktreeRoot = worktreeRoot
        self.claudeTrust = claudeTrust
    }

    public static func sessionID(for worktree: Worktree) -> String { "wt-\(worktree.id.uuidString)" }

    /// Global → `.bullpen.toml` (plus per-agent append) → project → task, with variables filled.
    public static func composePrompt(_ request: WorktreeRequest, config: BullpenConfig, path: String) throws -> String? {
        let repository = [config.prompt, request.agent.flatMap { config.agentPrompts[$0.id] }]
            .compactMap { $0 }.joined(separator: "\n\n")
        return try PromptComposer.compose(
            global: request.sendInitialPrompt ? request.globalPrompt : nil,
            repository: request.sendInitialPrompt ? repository : nil,
            project: request.sendInitialPrompt ? request.project.initialPrompt : nil,
            task: request.task,
            variables: PromptComposer.variables(
                projectName: request.project.name, branch: request.branch, baseRef: request.baseRef,
                path: path, task: request.task?.nilIfBlank
            )
        )
    }

    public func path(for request: WorktreeRequest) -> URL {
        WorktreeLocation.path(project: request.project.name, branch: request.branch, root: worktreeRoot)
    }

    @discardableResult
    public func createWorktree(_ request: WorktreeRequest) async throws -> Worktree {
        let projectURL = URL(fileURLWithPath: request.project.path)
        let repo = try await Repository.open(at: projectURL)
        guard await repo.isValidBranchName(request.branch) else {
            throw WorkspaceError(message: "“\(request.branch)” no es un nombre de rama válido.")
        }
        let path = path(for: request)
        // Validate config and prompt before touching git, so mistakes leave nothing behind.
        let config = try BullpenConfig.load(from: projectURL)
        let prompt = try request.agent.map { _ in try Self.composePrompt(request, config: config, path: path.path) } ?? nil
        _ = try config.resolvedEnvironment(
            ports: Dictionary(uniqueKeysWithValues: config.portNames.map { ($0, 0) }),
            variables: PromptComposer.variables(projectName: request.project.name, branch: request.branch,
                                                baseRef: request.baseRef, path: path.path, task: request.task)
        )

        try await repo.addWorktree(branch: request.branch, at: path, baseRef: request.baseRef)
        let taken = Set(try database.offices().flatMap(\.worktrees).flatMap { Array(($0.ports ?? [:]).values) })
        let ports = PortAllocator.allocate(names: config.portNames, taken: taken)
        let worktree = Worktree(
            projectID: request.project.id, branch: request.branch, path: path.path, baseRef: request.baseRef,
            agentProfileID: request.agent?.id, agentModel: request.model?.nilIfBlank,
            taskDescription: request.task?.nilIfBlank, ports: ports.isEmpty ? nil : ports, runID: request.runID,
            ticket: request.ticket
        )
        let report = try WorktreeSetup.prepare(config: config, from: projectURL, to: path)
        if !report.missing.isEmpty {
            log.info("Setup skipped missing paths: \(report.missing.joined(separator: ", "), privacy: .public)")
        }
        try database.save(worktree)

        if request.agent?.id == AgentProfile.claude.id, let claudeTrust {
            do { try claudeTrust.trust(path.path) } catch {
                log.warning("Cannot pre-trust worktree for Claude: \(error.localizedDescription, privacy: .public)")
            }
        }

        // [setup] runs first in the worktree's terminal; the agent starts only if it succeeds.
        let launch = request.agent?.launch(model: request.model?.nilIfBlank, prompt: prompt, hooks: hooks)
        if let command = WorktreeSetup.command(setup: config.setup, then: launch?.command) {
            let env = try WorktreeEnvironment.load(project: request.project, worktree: worktree)
            let client = try await connect()
            let id = Self.sessionID(for: worktree)
            _ = try await client.create(SessionSpec(id: id, cwd: path.path, command: command, environment: env.environment))
            if let typed = launch?.typedPrompt {
                if request.awaitTypedPrompt {
                    try await Self.typeWhenReady(typed, session: id, client: client)
                } else {
                    Task.detached { try? await Self.typeWhenReady(typed, session: id, client: client) }
                }
            }
        }
        return worktree
    }

    /// Waits until the agent has drawn its interface and gone quiet, then types the prompt.
    static func typeWhenReady(_ prompt: String, session: String, client: SessionClient,
                              quiet: TimeInterval = 1.5, timeout: TimeInterval = 45) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let info = try await client.list().first(where: { $0.id == session }), info.isRunning else { return }
            if let last = info.lastOutputAt, Date().timeIntervalSince(info.startedAt) > 2, Date().timeIntervalSince(last) > quiet {
                break
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        try await client.sendMessage(session, prompt)
    }

    /// One agent variant of a run.
    public struct Variant: Sendable {
        public var agent: AgentProfile
        public var model: String?
        public init(agent: AgentProfile, model: String? = nil) {
            self.agent = agent
            self.model = model
        }
    }

    /// Branch for each variant: `<base>-<agent>`, numbered when an agent appears more than once.
    public static func branchNames(base: String, variants: [Variant]) -> [String] {
        var seen: [String: Int] = [:]
        let totals = Dictionary(grouping: variants, by: \.agent.id).mapValues(\.count)
        return variants.map { variant in
            let id = variant.agent.id
            seen[id, default: 0] += 1
            return totals[id, default: 0] > 1 ? "\(base)-\(id)-\(seen[id]!)" : "\(base)-\(id)"
        }
    }

    /// Fan-out (PLAN §11.2): the same task to several agents, each in its own worktree.
    /// Validates everything first; if a later worktree fails, the earlier ones stay (and are reported).
    @discardableResult
    public func createRun(_ base: WorktreeRequest, variants: [Variant]) async throws -> (Run, [Worktree]) {
        guard variants.count >= 2 else { throw WorkspaceError(message: "Una comparación necesita al menos dos agentes.") }
        guard let task = base.task?.nilIfBlank else { throw WorkspaceError(message: "Escribe la tarea que harán todos.") }
        let run = Run(projectID: base.project.id, task: task)
        try database.save(run)
        var created: [Worktree] = []
        for (variant, branch) in zip(variants, Self.branchNames(base: base.branch, variants: variants)) {
            var request = base
            request.branch = branch
            request.agent = variant.agent
            request.model = variant.model
            request.runID = run.id
            created.append(try await createWorktree(request))
        }
        return (run, created)
    }

    /// Hangs up the terminal, runs `[teardown]`, removes the folder (the branch stays) and archives it.
    public func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool) async throws {
        let id = Self.sessionID(for: worktree)
        if let client = try? await connect() {
            try? await client.kill(id, signal: SIGHUP)
            for _ in 0..<20 {
                guard let session = try? await client.list().first(where: { $0.id == id }), session.isRunning else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await client.remove(id)
        }
        let path = URL(fileURLWithPath: worktree.path)
        if FileManager.default.fileExists(atPath: path.path) {
            if let env = try? WorktreeEnvironment.load(project: project, worktree: worktree), !env.config.teardown.isEmpty {
                let results = await CommandRunner.run(env.config.teardown, in: path, environment: env.environment, timeout: 120, stopOnFailure: false)
                for failed in results where !failed.succeeded {
                    log.warning("Teardown failed: \(failed.command, privacy: .public) (\(failed.exitCode))")
                }
            }
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            try await repo.removeWorktree(at: path, force: force)
        }
        try? claudeTrust?.forget(worktree.path)
        var archived = worktree
        archived.archivedAt = Date()
        try database.save(archived)
    }
}

public extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
