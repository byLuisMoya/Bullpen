import BPAgents
import BPCore
import BPGit
import BPPersistence
import Foundation
import Observation
import os

/// Main-actor view model: the building (offices stacked by project) read from the database.
@MainActor
@Observable
final class BuildingStore {
    private(set) var offices: [Office] = []
    /// Last error to show to the user; cleared when dismissed.
    var errorMessage: String?
    private var database: AppDatabase?
    private let log = Logger.bullpen("store")

    func start() async {
        do {
            let database = try AppDatabase.onDisk()
            self.database = database
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

    /// Creates the git worktree and records it. Returns nil (and sets `errorMessage`) on failure.
    func createWorktree(in project: Project, branch: String, baseRef: String,
                        agent: String?, model: String?, task: String?) async -> Worktree? {
        guard let database else { return nil }
        do {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            guard await repo.isValidBranchName(branch) else {
                errorMessage = "“\(branch)” no es un nombre de rama válido."
                return nil
            }
            let path = WorktreeLocation.path(project: project.name, branch: branch)
            try await repo.addWorktree(branch: branch, at: path, baseRef: baseRef)
            let worktree = Worktree(
                projectID: project.id, branch: branch, path: path.path, baseRef: baseRef,
                agentProfileID: agent, agentModel: model?.nilIfBlank, taskDescription: task?.nilIfBlank
            )
            try database.save(worktree)
            // Claude Code asks to trust every new folder; worktrees are ours, so pre-trust them.
            do {
                try ClaudeTrust().trust(path.path)
            } catch {
                log.warning("Cannot pre-trust worktree for Claude: \(error.localizedDescription, privacy: .public)")
            }
            return worktree
        } catch {
            report(error, "Create worktree failed")
            return nil
        }
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

    /// Removes the worktree folder (the branch is kept) and archives it in the database.
    func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool) async {
        guard let database else { return }
        do {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            let path = URL(fileURLWithPath: worktree.path)
            if FileManager.default.fileExists(atPath: path.path) {
                try await repo.removeWorktree(at: path, force: force)
            }
            try? ClaudeTrust().forget(worktree.path)
            var archived = worktree
            archived.archivedAt = Date()
            try database.save(archived)
        } catch {
            report(error, "Remove worktree failed")
        }
    }

    private func report(_ error: Error, _ context: String) {
        log.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
