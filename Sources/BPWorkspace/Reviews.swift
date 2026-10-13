import BPAgents
import BPCore
import BPGit
import BPSessions
import Foundation

/// Reviewers: agents in the "Reviews" office that review another worktree's PR in a detached
/// checkout of the same commit. Their fixes stay uncommitted until the user accepts them.
public extension Workspace {
    /// The Reviews office, created the first time it is needed (it is not a repository).
    @discardableResult
    func ensureReviewsProject() throws -> Project {
        if let existing = try database.offices().first(where: { $0.project.isReviews })?.project { return existing }
        let folder = worktreeRoot.deletingLastPathComponent().appendingPathComponent("reviews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(id: Project.reviewsID, name: "Reviews", path: folder.path, sortIndex: 10_000)
        try database.save(project)
        return project
    }

    /// The commit a worktree is at.
    func headCommit(of worktree: Worktree) async throws -> String {
        try await Git().run(["rev-parse", "HEAD"], in: URL(fileURLWithPath: worktree.path))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files the worktree's branch changes against its base (to pick the quick or the exhaustive review).
    func changedFileCount(of worktree: Worktree) async -> Int? {
        let out = try? await Git().run(["diff", "--name-only", "\(worktree.baseRef)...HEAD"], in: URL(fileURLWithPath: worktree.path))
        return out.map { $0.split(separator: "\n").count }
    }

    /// Starts a reviewer for `worktree` (of `project`) with `prompt` as its first message.
    @discardableResult
    func createReview(of worktree: Worktree, in project: Project, kind: ReviewInfo.Kind, pullRequest: Int?,
                      prompt: String, agent: AgentProfile = .claude) async throws -> Worktree {
        let reviews = try ensureReviewsProject()
        let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
        let commit = try await headCommit(of: worktree)
        let name = "\(WorktreeLocation.slug(project.name))-\(WorktreeLocation.slug(worktree.branch))-\(commit.prefix(7))"
        var path = worktreeRoot.appendingPathComponent("Reviews", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: path.path) {
            path = path.deletingLastPathComponent().appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Git().run(["worktree", "add", "--detach", path.path, commit], in: repo.root)

        let info = ReviewInfo(of: worktree.id, kind: kind, repoPath: repo.root.path, branch: worktree.branch,
                              pullRequest: pullRequest, commit: commit)
        let reviewer = Worktree(
            projectID: reviews.id, branch: worktree.branch, path: path.path, baseRef: commit,
            agentProfileID: agent.id,
            taskDescription: "\(kind == .quick ? "Revisión rápida" : "Revisión exhaustiva") de \(worktree.branch) (\(project.name))",
            review: info
        )
        try database.save(reviewer)
        if agent.id == AgentProfile.claude.id { try? claudeTrust?.trust(path.path) }
        hooks.prepare(agent, in: path.path)
        let launch = agent.launch(model: nil, prompt: prompt, hooks: hooks)
        let client = try await connect()
        _ = try await client.create(SessionSpec(
            id: Self.sessionID(for: reviewer), cwd: path.path, command: launch.command,
            environment: ["BULLPEN_PROJECT_PATH": project.path, "BULLPEN_WORKTREE": worktree.branch]
        ))
        if let typed = launch.typedPrompt {
            let id = Self.sessionID(for: reviewer)
            Task.detached { try? await Self.typeWhenReady(typed, session: id, client: client) }
        }
        return reviewer
    }

    /// What accepting a reviewer's fixes did.
    struct AppliedFixes: Sendable {
        public var commit: String?
        /// The reviewed worktree was moved to the new commit too.
        public var updatedOriginal: Bool
    }

    /// Commits the reviewer's fixes, pushes them to the PR's branch and moves the reviewed
    /// worktree there when it hasn't changed since. No changes: nothing to commit.
    func applyReviewFixes(_ reviewer: Worktree) async throws -> AppliedFixes {
        guard var info = reviewer.review else { throw WorkspaceError(message: "No es un revisor.") }
        let git = Git(), path = URL(fileURLWithPath: reviewer.path)
        try await git.run(["add", "-A"], in: path)
        let staged = try await git.run(["diff", "--cached", "--name-only"], in: path)
        guard !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AppliedFixes(commit: nil, updatedOriginal: false)
        }
        let label = info.kind == .quick ? "rápida" : "exhaustiva"
        try await git.run(["commit", "-m", "Arreglos de la revisión \(label)"], in: path)
        let commit = try await git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try await git.run(["push", "origin", "HEAD:refs/heads/\(info.branch)"], in: path)

        var updated = false
        if let original = try database.allWorktrees().first(where: { $0.id == info.of && $0.isActive }) {
            let at = URL(fileURLWithPath: original.path)
            let clean = ((try? await git.run(["status", "--porcelain"], in: at)) ?? "x").isEmpty
            let head = (try? await git.run(["rev-parse", "HEAD"], in: at))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean, head == info.commit, (try? await git.run(["merge", "--ff-only", commit], in: at)) != nil { updated = true }
        }
        info.phase = .applied
        info.appliedCommit = commit
        var saved = reviewer
        saved.review = info
        try database.save(saved)
        return AppliedFixes(commit: commit, updatedOriginal: updated)
    }

    func saveReview(_ info: ReviewInfo, for reviewer: Worktree) throws {
        var saved = reviewer
        saved.review = info
        try database.save(saved)
    }
}
