import BPCore
import BPGit
import BPPersistence
import Foundation
import Observation
import os
import UserNotifications

/// Branch and pull-request state per worktree, shown to the right of each sidebar row like Orca.
/// Branch sync is local git (cheap, every 15 s); PRs come from `gh` once a minute per project.
@MainActor
@Observable
final class RepoStatusCenter {
    private(set) var branches: [UUID: BranchSync] = [:]
    private(set) var pullRequests: [UUID: PullRequest] = [:]
    /// Finished agent turns per worktree (its checkpoints): earns things on its desk.
    private(set) var turns: [UUID: Int] = [:]
    /// Files this worktree shares with others (overlap) or that would conflict when merging.
    private(set) var warnings: [UUID: WorktreeWarning] = [:]
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
        var nextTurns: [UUID: Int] = [:]
        var nextPRs: [UUID: PullRequest] = includePRs ? [:] : pullRequests
        var nextWarnings: [UUID: WorktreeWarning] = includePRs ? [:] : warnings
        for office in store.offices where !office.worktrees.isEmpty {
            guard let repo = try? await Repository.open(at: URL(fileURLWithPath: office.project.path)) else { continue }
            for worktree in office.worktrees {
                nextBranches[worktree.id] = await repo.branchSync(worktree.branch)
                nextTurns[worktree.id] = (try? await repo.checkpoints(of: worktree.id).count) ?? 0
            }
            if includePRs {
                // Pairwise merge simulations are the costly part: same cadence as PRs.
                let report = await repo.overlapReport(office.worktrees.map {
                    (branch: $0.branch, path: URL(fileURLWithPath: $0.path), baseRef: $0.baseRef)
                })
                // Agents of the same comparison run are expected to touch the same files: not a warning.
                let runOf = Dictionary(office.worktrees.map { ($0.branch, $0.runID) }, uniquingKeysWith: { a, _ in a })
                for worktree in office.worktrees {
                    func unrelated(_ others: [String: [String]]) -> [String: [String]] {
                        others.filter { worktree.runID == nil || runOf[$0.key] ?? nil != worktree.runID }
                    }
                    nextWarnings[worktree.id] = WorktreeWarning(
                        conflicts: unrelated(report.conflicts[worktree.branch] ?? [:]),
                        overlaps: unrelated(report.overlaps[worktree.branch] ?? [:])
                    )
                }
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
        // Only count it as a full refresh once there was something to look at.
        if includePRs, !store.offices.isEmpty { lastPRFetch = Date() }
        branches = nextBranches
        if nextTurns != turns { turns = nextTurns }
        if includePRs { announceFinishedChecks(old: pullRequests, new: nextPRs, store: store) }
        pullRequests = nextPRs
        warnings = nextWarnings.filter { !$0.value.isEmpty }
    }

    /// A banner when a worktree's PR checks finish (were running, now pass or fail): the badge
    /// colour alone is easy to miss while working in another app.
    private func announceFinishedChecks(old: [UUID: PullRequest], new: [UUID: PullRequest], store: BuildingStore) {
        for office in store.offices {
            for worktree in office.worktrees {
                guard let before = old[worktree.id], let after = new[worktree.id], before.number == after.number,
                      before.checks == .pending, after.checks == .success || after.checks == .failure else { continue }
                let content = UNMutableNotificationContent()
                content.title = after.checks == .failure ? "Checks fallando en la PR #\(after.number)" : "Checks pasando en la PR #\(after.number)"
                content.subtitle = office.project.name
                content.body = worktree.branch
                content.threadIdentifier = worktree.id.uuidString
                content.sound = after.checks == .failure ? .default : nil
                let request = UNNotificationRequest(identifier: "checks-\(worktree.id.uuidString)", content: content, trigger: nil)
                Task {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    guard settings.authorizationStatus == .authorized else { return }
                    try? await UNUserNotificationCenter.current().add(request)
                }
            }
        }
    }
}

struct WorktreeWarning: Equatable {
    var conflicts: [String: [String]]
    var overlaps: [String: [String]]
    var isEmpty: Bool { conflicts.isEmpty && overlaps.isEmpty }
    var isConflict: Bool { !conflicts.isEmpty }

    var tooltip: String {
        var lines: [String] = []
        for (branch, files) in conflicts.sorted(by: { $0.key < $1.key }) {
            lines.append("Conflicto al fusionar con \(branch): \(files.joined(separator: ", "))")
        }
        for (branch, files) in overlaps.sorted(by: { $0.key < $1.key }) where conflicts[branch] == nil {
            lines.append("También toca \(files.joined(separator: ", ")) en \(branch)")
        }
        return lines.joined(separator: "\n")
    }
}
