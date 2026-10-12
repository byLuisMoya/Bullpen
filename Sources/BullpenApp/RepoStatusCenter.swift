import BPCore
import BPGit
import BPPersistence
import Foundation
import Observation
import os

/// Branch and pull-request state per worktree, shown to the right of each sidebar row like Orca.
/// Branch sync is local git (cheap, every 15 s); PRs come from `gh` once a minute per project.
@MainActor
@Observable
final class RepoStatusCenter {
    private(set) var branches: [UUID: BranchSync] = [:]
    private(set) var pullRequests: [UUID: PullRequest] = [:]
    @ObservationIgnored private let gh = GitHubCLI.locate()
    @ObservationIgnored private var lastPRFetch: Date = .distantPast
    @ObservationIgnored private let log = Logger.bullpen("repo-status")

    func start(store: BuildingStore) async {
        while !Task.isCancelled {
            await refresh(store: store, includePRs: Date().timeIntervalSince(lastPRFetch) > 60)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    func refresh(store: BuildingStore, includePRs: Bool) async {
        var nextBranches: [UUID: BranchSync] = [:]
        var nextPRs: [UUID: PullRequest] = includePRs ? [:] : pullRequests
        for office in store.offices where !office.worktrees.isEmpty {
            guard let repo = try? await Repository.open(at: URL(fileURLWithPath: office.project.path)) else { continue }
            for worktree in office.worktrees {
                nextBranches[worktree.id] = await repo.branchSync(worktree.branch)
            }
            guard includePRs, let gh else { continue }
            do {
                let prs = try await gh.pullRequests(in: repo.root)
                for worktree in office.worktrees {
                    nextPRs[worktree.id] = prs[worktree.branch]
                }
            } catch {
                // Not a GitHub repo, offline or gh signed out: just show no PR.
                log.debug("gh pr list failed for \(office.project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if includePRs { lastPRFetch = Date() }
        branches = nextBranches
        pullRequests = nextPRs
    }
}
