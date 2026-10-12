import Foundation

/// Whether a worktree's branch exists on the remote and how far it is from it.
public struct BranchSync: Equatable, Sendable {
    /// `origin/<branch>` exists locally (pushed at least once, or fetched).
    public var isPushed: Bool
    /// Local commits not on the remote branch.
    public var ahead: Int
    /// Remote commits not in the local branch.
    public var behind: Int

    public init(isPushed: Bool, ahead: Int = 0, behind: Int = 0) {
        self.isPushed = isPushed
        self.ahead = ahead
        self.behind = behind
    }
}

public extension Repository {
    /// Local-only check (no network): compares the branch with its `origin/` remote-tracking ref.
    func branchSync(_ branch: String, remote: String = "origin") async -> BranchSync {
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        guard (try? await git.run(["rev-parse", "--verify", "--quiet", remoteRef], in: root)) != nil else {
            return BranchSync(isPushed: false)
        }
        let counts = (try? await git.run(["rev-list", "--left-right", "--count", "\(branch)...\(remoteRef)"], in: root)) ?? ""
        let numbers = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return BranchSync(isPushed: true, ahead: numbers.first ?? 0, behind: numbers.dropFirst().first ?? 0)
    }
}
