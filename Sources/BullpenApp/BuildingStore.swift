import BPAgents
import BPCore
import BPEnv
import BPGit
import BPSessions
import BPWorkspace
import BPPersistence
import Foundation
import Observation
import os

/// Main-actor view model: the building (offices stacked by project) read from the database.
@MainActor
@Observable
final class BuildingStore {
    /// How to reach bpd (the session manager's connection, which can launch it).
    @ObservationIgnored var connectToDaemon: @Sendable () async throws -> SessionClient = { try SessionClient.connect() }
    @ObservationIgnored var hooks = AgentHooks.standard(bpPath: "/usr/local/bin/bp")
    private(set) var offices: [Office] = []
    /// Last error to show to the user; cleared when dismissed.
    var errorMessage: String?
    private var database: AppDatabase?
    private let log = Logger.bullpen("store")

    func start() async {
        do {
            let database = try AppDatabase.onDisk()
            self.database = database
            workspace = Workspace(database: database, connect: connectToDaemon, hooks: hooks)
            // GRDB observes this process's writes; `bp` writes from another process, so re-read now and then.
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let fresh = try? database.offices(), fresh != self.offices else { continue }
                    self.offices = fresh
                }
            }
            for try await offices in database.observeOffices() {
                self.offices = offices
            }
        } catch {
            report(error, "Database failed")
        }
    }

    // MARK: Projects

    /// Registers the git repository containing `url` as a new office.
    func addProject(at url: URL) async {
        guard let database else { return }
        do {
            let repo = try await Repository.open(at: url)
            if offices.contains(where: { $0.project.path == repo.root.path }) {
                errorMessage = "\(repo.name) ya está en el edificio."
                return
            }
            let project = Project(
                name: repo.name,
                path: repo.root.path,
                defaultBaseRef: try await repo.currentBranch(),
                sortIndex: (offices.map(\.project.sortIndex).max() ?? -1) + 1
            )
            try database.save(project)
        } catch is GitError {
            errorMessage = "\(url.lastPathComponent) no es un repositorio git."
        } catch {
            report(error, "Add project failed")
        }
    }

    // MARK: Worktrees

    func updateProject(_ project: Project) {
        do {
            try database?.save(project)
        } catch {
            report(error, "Update project failed")
        }
    }

    /// Shared create/remove logic (also used by the CLI). Set once the database is open.
    var workspace: Workspace?

    /// Creates the worktree end to end. Returns nil (and sets `errorMessage`) on failure.
    func createWorktree(_ request: WorktreeRequest) async -> Worktree? {
        guard let workspace else { return nil }
        do {
            return try await workspace.createWorktree(request)
        } catch {
            report(error, "Create worktree failed")
            return nil
        }
    }

    /// Fan-out: same task to several agents (PLAN §11.2).
    func createRun(_ request: WorktreeRequest, variants: [Workspace.Variant]) async -> [Worktree]? {
        guard let workspace else { return nil }
        do {
            return try await workspace.createRun(request, variants: variants).1
        } catch {
            report(error, "Create run failed")
            return nil
        }
    }

    func run(id: UUID) -> Run? { try? database?.run(id: id) }
    func runMembers(_ id: UUID) -> [Worktree] { (try? database?.worktrees(inRun: id)) ?? [] }

    func saveVerdict(_ verdict: String, for run: Run) {
        var updated = run
        updated.verdict = verdict
        try? database?.save(updated)
    }

    /// What would be lost by removing this worktree; empty means it is safe.
    func removalGuards(for worktree: Worktree, in project: Project) async -> [RemovalGuard] {
        do {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            return try await repo.removalGuards(for: URL(fileURLWithPath: worktree.path), baseRef: worktree.baseRef)
        } catch {
            // If git cannot inspect it (e.g. folder already gone) there is nothing left to protect.
            log.warning("Guards check failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Hangs up its terminal, runs teardown, removes the folder (the branch is kept) and archives it.
    func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool) async {
        do {
            try await workspace?.removeWorktree(worktree, in: project, force: force)
        } catch {
            report(error, "Remove worktree failed")
        }
    }

    private func report(_ error: Error, _ context: String) {
        log.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}

extension RemovalGuard {
    var message: String {
        switch self {
        case let .uncommittedChanges(count): "\(count) fichero(s) con cambios sin commitear"
        case let .unpushedCommits(count): "\(count) commit(s) que no están en remoto ni en la rama base"
        case .locked: "el worktree está bloqueado"
        }
    }
}
