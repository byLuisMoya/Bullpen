import BPAgents
import BPCore
import BPGit
import Foundation

public extension Workspace {
    /// Runs a scheduled task now: a new worktree in its project, on a dated branch (with a suffix
    /// if that branch already exists), with its agent started on the task. Marks it as run first,
    /// so a failure doesn't retry in a loop.
    @discardableResult
    func run(_ automation: Automation, defaultAgent: String, globalPrompt: String?, now: Date = Date()) async throws -> Worktree {
        var marked = automation
        marked.lastRun = now
        try database.save(marked)
        guard let project = try database.offices().first(where: { $0.project.id == automation.projectID })?.project else {
            throw WorkspaceError(message: "El proyecto de «\(automation.name)» ya no está en Bullpen.")
        }
        let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
        let base = automation.branchName(on: now)
        var branch = base, n = 2
        while await repo.branchExists(branch) || FileManager.default.fileExists(atPath: path(for: WorktreeRequest(project: project, branch: branch, baseRef: "")).path) {
            branch = "\(base)-\(n)"
            n += 1
        }
        let agent = AgentProfile.named(automation.agentID ?? defaultAgent) ?? AgentProfile.named(defaultAgent)
        let request = WorktreeRequest(project: project, branch: branch, baseRef: project.defaultBaseRef ?? "main", agent: agent,
                                      task: automation.task, globalPrompt: globalPrompt, sendInitialPrompt: true)
        return try await createWorktree(request)
    }
}
