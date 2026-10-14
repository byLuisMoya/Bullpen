import Foundation

/// The repository's refs that the status poll needs, read in one git run: branch tips,
/// remote-tracking tips and how many checkpoints each worktree has.
public struct RefState: Equatable, Sendable {
    /// branch → commit
    public var heads: [String: String] = [:]
    /// branch (without `origin/`) → commit
    public var remotes: [String: String] = [:]
    /// worktree → checkpoints (same count as `checkpoints(of:)`)
    public var checkpoints: [UUID: Int] = [:]

    public init() {}

    static func parse(_ output: String, remote: String) -> RefState {
        var state = RefState()
        let remotePrefix = "refs/remotes/\(remote)/", checkpointPrefix = "refs/bullpen/checkpoints/"
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (commit, ref) = (parts[0], parts[1])
            if ref.hasPrefix("refs/heads/") {
                state.heads[String(ref.dropFirst("refs/heads/".count))] = commit
            } else if ref.hasPrefix(remotePrefix) {
                state.remotes[String(ref.dropFirst(remotePrefix.count))] = commit
            } else if ref.hasPrefix(checkpointPrefix) {
                // `<uuid>/<number>`
                let rest = ref.dropFirst(checkpointPrefix.count).split(separator: "/")
                guard rest.count == 2, let id = UUID(uuidString: String(rest[0])), Int(rest[1]) != nil else { continue }
                state.checkpoints[id, default: 0] += 1
            }
        }
        return state
    }
}

public extension Repository {
    func refState(remote: String = "origin") async -> RefState? {
        guard let output = try? await git.run(["for-each-ref", "--format=%(objectname) %(refname)",
                                               "refs/heads", "refs/remotes/\(remote)", "refs/bullpen/checkpoints"], in: root) else { return nil }
        return RefState.parse(output, remote: remote)
    }

    /// `branchSync` from tips already read: git runs only for ahead/behind, and `counts` keeps
    /// them by the pair of commits, which is all they depend on.
    func branchSync(_ branch: String, in state: RefState, counts: GitResultCache<[Int]>, remote: String = "origin") async -> BranchSync {
        guard let remoteTip = state.remotes[branch] else { return BranchSync(isPushed: false) }
        guard let localTip = state.heads[branch] else { return BranchSync(isPushed: true) }
        let numbers = await counts.value(for: "\(localTip)...\(remoteTip)") {
            (try? await git.run(["rev-list", "--left-right", "--count", "\(localTip)...\(remoteTip)"], in: root))
                .map { $0.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } }
        } ?? []
        return BranchSync(isPushed: true, ahead: numbers.first ?? 0, behind: numbers.dropFirst().first ?? 0)
    }
}

/// Results of git commands that only depend on commits (which never change), by those commits.
public final class GitResultCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    private let limit: Int

    public init(limit: Int = 2_000) { self.limit = limit }

    /// The cached value, or `compute`'s; a failure (nil) isn't kept, so the next call tries again.
    public func value(for key: String, compute: () async -> Value?) async -> Value? {
        if let known = lock.withLock({ values[key] }) { return known }
        guard let value = await compute() else { return nil }
        lock.withLock {
            if values.count >= limit { values.removeAll() }
            values[key] = value
        }
        return value
    }
}
