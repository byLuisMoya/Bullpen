import Foundation

/// Files touched by more than one active worktree, and branches that would conflict when merged
/// together (PLAN §6.3). Computed per project without touching any working tree.
public struct OverlapReport: Equatable, Sendable {
    /// branch → (other branch → shared files)
    public var overlaps: [String: [String: [String]]] = [:]
    /// branch → (other branch → conflicting files)
    public var conflicts: [String: [String: [String]]] = [:]

    public init() {}
}

public extension Repository {
    /// Paths changed on the worktree's branch since its merge base with `baseRef`, plus uncommitted
    /// and untracked files.
    func changedPaths(in path: URL, baseRef: String) async throws -> Set<String> {
        let committedAndDirty = try await git.run(["diff", "--name-only", "--merge-base", baseRef], in: path)
        let untracked = try await git.run(["ls-files", "--others", "--exclude-standard"], in: path)
        return Set((committedAndDirty + "\n" + untracked).split(separator: "\n").map(String.init))
    }

    /// Files that would conflict if `a` and `b` were merged (committed work only); empty if clean.
    func mergeConflicts(_ a: String, _ b: String) async throws -> [String] {
        // Exit 1 means "conflicts"; the output is the tree id and then one conflicted path per line.
        let output = try await git.runAllowingDifferences(
            ["merge-tree", "--write-tree", "--name-only", "--no-messages", a, b], in: root
        )
        let lines = output.split(separator: "\n").map(String.init)
        return Array(Set(lines.dropFirst())).sorted()
    }

    /// Overlaps and conflicts among `worktrees` (branch, path, base ref).
    func overlapReport(_ worktrees: [(branch: String, path: URL, baseRef: String)]) async -> OverlapReport {
        var report = OverlapReport()
        guard worktrees.count > 1 else { return report }
        var changed: [String: Set<String>] = [:]
        for wt in worktrees {
            changed[wt.branch] = (try? await changedPaths(in: wt.path, baseRef: wt.baseRef)) ?? []
        }
        for i in worktrees.indices {
            for j in worktrees.indices where j > i {
                let a = worktrees[i].branch, b = worktrees[j].branch
                let shared = changed[a, default: []].intersection(changed[b, default: []]).sorted()
                if !shared.isEmpty {
                    report.overlaps[a, default: [:]][b] = shared
                    report.overlaps[b, default: [:]][a] = shared
                }
                if let conflicting = try? await mergeConflicts(a, b), !conflicting.isEmpty {
                    report.conflicts[a, default: [:]][b] = conflicting
                    report.conflicts[b, default: [:]][a] = conflicting
                }
            }
        }
        return report
    }
}
