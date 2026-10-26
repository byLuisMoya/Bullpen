import BPAgents
import BPCore
import BPEnv
import BPGit
import BPSessions
import BPWorkspace
import BPPersistence
import Foundation
import UserNotifications
import Observation
import os

/// Main-actor view model: the building (offices stacked by project) read from the database.
@MainActor
@Observable
final class BuildingStore {
    /// How to reach bpd (the session manager's connection, which can launch it).
    @ObservationIgnored var connectToDaemon: @Sendable () async throws -> SessionClient = { try SessionClient.connect() }
    @ObservationIgnored var hooks = AgentHooks.standard(bpPath: "/usr/local/bin/bp")
    private(set) var offices: [Office] = [] {
        didSet {
            // Their desk is gone: nobody left to walk out.
            let present = Set(offices.flatMap(\.worktrees).map(\.id))
            if !leaving.isSubset(of: present) { leaving.formIntersection(present) }
        }
    }
    /// Last error to show to the user; cleared when dismissed.
    var errorMessage: String?
    /// Worktrees being deleted: their person walks out while the terminal and folder go. Kept
    /// until the desk is gone, or it would be back for a moment and walk out a second time.
    private(set) var leaving: Set<UUID> = []
    /// Review checkouts no reviewer points at that still have changes: the user decides.
    var orphanReviews: [URL] = []
    private var database: AppDatabase?
    /// Counts the observation's deliveries, so a slower re-read can't put an older building back.
    @ObservationIgnored private var observedVersion = 0
    private let log = Logger.bullpen("store")

    func start() async {
        do {
            let database = try AppDatabase.onDisk()
            self.database = database
            workspace = Workspace(database: database, connect: connectToDaemon, hooks: hooks)
            workspace?.deletesInBackground = true
            // The Reviews office is always there.
            do { try workspace?.ensureReviewsProject() } catch { report(error, "Reviews office failed") }
            // Worktrees made with Orca (or plain git) in these projects show up here too.
            Task { [weak self] in
                while !Task.isCancelled {
                    if let workspace = self?.workspace { _ = try? await workspace.syncExternalWorktrees() }
                    await Pacing.pause(active: 20, background: 60)
                }
            }
            // GRDB observes this process's writes; `bp` writes from another process, so re-read now and then.
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    // Read off the main thread: a write in progress (or a busy disk) must not stall the UI.
                    guard let version = self?.observedVersion else { return }
                    let fresh = await offPool { try? database.offices() }
                    // The observation may have brought something newer meanwhile: that one wins. (One
                    // committed during the read but not delivered yet still lands right after.)
                    guard let self, version == self.observedVersion, let fresh, fresh != self.offices else { continue }
                    self.offices = fresh
                }
            }
            for try await offices in database.observeOffices() {
                observedVersion += 1
                if offices != self.offices { self.offices = offices }
            }
        } catch {
            report(error, "Database failed")
        }
    }

    /// At launch: clean review checkouts left behind go; the ones with changes wait for the user.
    func cleanOrphanReviews() async {
        guard let workspace else { return }
        do {
            let orphans = try await workspace.cleanOrphanReviews()
            if !orphans.removed.isEmpty {
                log.info("Removed orphan review checkouts: \(orphans.removed.joined(separator: ", "), privacy: .public)")
            }
            orphanReviews = orphans.withChanges
        } catch {
            log.error("Orphan review cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeOrphanReviews() async {
        guard let workspace else { return }
        for dir in orphanReviews {
            do { try await workspace.removeOrphanReview(dir) } catch { report(error, "Remove orphan review failed") }
        }
        orphanReviews = []
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

    /// Forgets a project with no active worktrees (nothing on disk is touched).
    func removeProject(_ project: Project) {
        do {
            try database?.deleteProject(id: project.id)
        } catch {
            report(error, "Remove project failed")
        }
    }

    /// Moves an office to where `target` is in the building (and the sidebar), pushing the rest along.
    func moveProject(_ id: UUID, to target: UUID) {
        var ids = offices.map(\.project.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        reorder(ids)
    }

    /// Moves an office one floor up (negative) or down (positive).
    func moveProject(_ id: UUID, by offset: Int) {
        var ids = offices.map(\.project.id)
        guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return }
        ids.swapAt(from, from + offset)
        reorder(ids)
    }

    private func reorder(_ ids: [UUID]) {
        // Right away here; the database observation then brings the same order back.
        // Counted as observed, so a re-read already under way (the old order) doesn't put it back.
        observedVersion += 1
        let byID = Dictionary(uniqueKeysWithValues: offices.map { ($0.project.id, $0) })
        offices = ids.enumerated().compactMap { index, id in
            guard var office = byID[id] else { return nil }
            office.project.sortIndex = index
            return office
        }
        do {
            try database?.reorderProjects(ids)
        } catch {
            report(error, "Reorder projects failed")
        }
    }

    // MARK: Automations

    private(set) var automations: [Automation] = []

    func reloadAutomations() {
        automations = (try? database?.automations()) ?? []
    }

    func save(_ automation: Automation) {
        do { try database?.save(automation) } catch { report(error, "Save automation failed") }
        reloadAutomations()
    }

    func delete(_ automation: Automation) {
        do { try database?.deleteAutomation(id: automation.id) } catch { report(error, "Delete automation failed") }
        reloadAutomations()
    }

    /// Runs it now; nil if creating its worktree failed (`errorMessage` when the user asked for
    /// it, a notification when it ran on its schedule).
    @discardableResult
    func run(_ automation: Automation, scheduled: Bool = false) async -> Worktree? {
        guard let workspace else { return nil }
        defer { reloadAutomations() }
        do {
            return try await workspace.run(automation, defaultAgent: PrimaryAgent.id,
                                           globalPrompt: UserDefaults.standard.string(forKey: "globalInitialPrompt"))
        } catch where scheduled {
            BackgroundNotice.post(id: "automation-\(automation.id)", title: "La automatización «\(automation.name)» ha fallado",
                                  body: error.localizedDescription, failure: true)
            return nil
        } catch {
            report(error, "Automation failed")
            return nil
        }
    }

    /// Every 30 s, runs what is due (and catches up once after the Mac was asleep or Bullpen closed).
    func runAutomations() async {
        while !Task.isCancelled {
            reloadAutomations()
            for automation in automations where automation.isDue(at: Date()) {
                guard let worktree = await run(automation, scheduled: true) else { continue }
                BackgroundNotice.post(id: "automation-\(automation.id)", title: "Automatización «\(automation.name)»",
                                      body: "Worktree \(worktree.branch) creado con su tarea.")
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Records which agent runs in a worktree (an Orca one adopting the main agent).
    func setAgent(_ agent: String, for worktree: Worktree) {
        var updated = worktree
        updated.agentProfileID = agent
        do { try database?.save(updated) } catch { report(error, "Update worktree failed") }
    }

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
            let repo = try await Repository.open(at: URL(fileURLWithPath: worktree.review?.repoPath ?? project.path))
            return try await repo.removalGuards(for: URL(fileURLWithPath: worktree.path), baseRef: worktree.baseRef)
        } catch {
            // If git cannot inspect it (e.g. folder already gone) there is nothing left to protect.
            log.warning("Guards check failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Hangs up its terminal, runs teardown, removes the folder (the branch is kept) and archives it.
    func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool, deleteExternal: Bool = false) async {
        leaving.insert(worktree.id)
        do {
            try await workspace?.removeWorktree(worktree, in: project, force: force, deleteExternal: deleteExternal)
        } catch {
            leaving.remove(worktree.id)
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
