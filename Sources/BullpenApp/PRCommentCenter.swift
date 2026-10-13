import BPCore
import BPGit
import Foundation
import os

/// New comments on a worktree's open PR go to its agent by the mailbox (so they arrive when it
/// finishes its turn). Comments already there when Bullpen first sees the PR are not news.
@MainActor
final class PRCommentCenter {
    static let enabledKey = "prComments.toAgent"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let seenKey = "prComments.seen"

    private let gh = GitHubCLI.locate()
    private var me: String?
    private let log = Logger.bullpen("pr-comments")

    func start(store: BuildingStore, repoStatus: RepoStatusCenter) async {
        while !Task.isCancelled {
            if Self.enabled { await check(store: store, repoStatus: repoStatus) }
            await Pacing.pause(active: 90, background: 180)
        }
    }

    private func check(store: BuildingStore, repoStatus: RepoStatusCenter) async {
        guard let gh, let database = store.workspace?.database else { return }
        var seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: [String]] ?? [:]
        var live: Set<String> = []
        for office in store.offices where !office.project.isReviews {
            for worktree in office.worktrees where worktree.agentProfileID != nil {
                guard let pr = repoStatus.pullRequests[worktree.id], pr.state == .open || pr.state == .draft else { continue }
                let key = "\(worktree.id.uuidString)#\(pr.number)"
                live.insert(key)
                let directory = URL(fileURLWithPath: worktree.path)
                do {
                    if me == nil { me = try? await gh.login(in: directory) }
                    let comments = try await gh.comments(ofPullRequest: pr.number, in: directory)
                    let known = Set(seen[key] ?? [])
                    defer { seen[key] = comments.map(\.id) }
                    // First look at this PR: what's there is the past.
                    guard seen[key] != nil else { continue }
                    let fresh = PullRequestComment.forAgent(comments.filter { !known.contains($0.id) }, me: me)
                    guard !fresh.isEmpty else { continue }
                    try database.save(AgentMessage(
                        projectID: office.project.id, toWorktree: worktree.id, fromWorktree: nil, fromLabel: "GitHub",
                        text: PullRequestComment.agentMessage(fresh, pullRequest: pr.number)
                    ))
                    BackgroundNotice.post(
                        id: "pr-comments-\(worktree.id)",
                        title: fresh.count == 1 ? "Comentario nuevo en la PR #\(pr.number)" : "\(fresh.count) comentarios nuevos en la PR #\(pr.number)",
                        body: "Se los paso al agente de \(worktree.branch) cuando termine su turno."
                    )
                } catch {
                    log.debug("PR comments of \(worktree.branch, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // Forget PRs that are gone (merged, closed, worktree removed).
        seen = seen.filter { live.contains($0.key) }
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
    }
}
