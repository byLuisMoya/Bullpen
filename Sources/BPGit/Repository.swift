import Foundation

/// A worktree as reported by `git worktree list --porcelain`.
public struct GitWorktree: Equatable, Sendable {
    public var path: String
    public var head: String?
    /// Short branch name (`feature/x`), nil when detached.
    public var branch: String?
    public var isMain: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
}

/// Why removing a worktree would lose something (PLAN §6.4). Each one needs explicit confirmation.
public enum RemovalGuard: Equatable, Sendable {
    case uncommittedChanges(count: Int)
    case unpushedCommits(count: Int)
    case locked
}

public struct Repository: Sendable {
    public let root: URL
    let git: Git

    /// Opens the repository containing `url`. Throws if it is not inside a git work tree.
    public static func open(at url: URL, git: Git = Git()) async throws -> Repository {
        let top = try await git.run(["rev-parse", "--show-toplevel"], in: url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Repository(root: URL(fileURLWithPath: top), git: git)
    }

    public var name: String { root.lastPathComponent }

    /// Branch checked out in the main worktree, used as default base ref.
    public func currentBranch() async throws -> String? {
        let name = try await git.run(["branch", "--show-current"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func isValidBranchName(_ name: String) async -> Bool {
        (try? await git.run(["check-ref-format", "--branch", name], in: root)) != nil
    }

    public func branchExists(_ name: String) async -> Bool {
        (try? await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: root)) != nil
    }

    public func worktrees() async throws -> [GitWorktree] {
        Self.parseWorktrees(try await git.run(["worktree", "list", "--porcelain"], in: root))
    }

    /// Creates `branch` from `baseRef` checked out at `path`. Reuses the branch if it already exists.
    public func addWorktree(branch: String, at path: URL, baseRef: String) async throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if await branchExists(branch) {
            try await git.run(["worktree", "add", path.path, branch], in: root)
        } else {
            try await git.run(["worktree", "add", "-b", branch, path.path, baseRef], in: root)
        }
    }

    /// What would be lost by removing the worktree at `path`.
    public func removalGuards(for path: URL, baseRef: String) async throws -> [RemovalGuard] {
        var guards: [RemovalGuard] = []
        let status = try await git.run(["status", "--porcelain"], in: path)
        let changes = status.split(separator: "\n").count
        if changes > 0 { guards.append(.uncommittedChanges(count: changes)) }

        // Commits not on the upstream, or not on the base ref when there is no upstream yet.
        let range: String
        if (try? await git.run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: path)) != nil {
            range = "@{upstream}..HEAD"
        } else {
            range = "\(baseRef)..HEAD"
        }
        if let count = Int(try await git.run(["rev-list", "--count", range], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 {
            guards.append(.unpushedCommits(count: count))
        }

        if try await worktrees().first(where: { samePath($0.path, path.path) })?.isLocked == true {
            guards.append(.locked)
        }
        return guards
    }

    /// Removes the worktree directory. Keeps the branch so work can be recovered.
    /// `force` is required when there are uncommitted changes or the worktree is locked.
    public func removeWorktree(at path: URL, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args += ["--force", "--force"] }
        args.append(path.path)
        try await git.run(args, in: root)
    }

    static func parseWorktrees(_ output: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        for block in output.components(separatedBy: "\n\n") where !block.isEmpty {
            var wt = GitWorktree(path: "", head: nil, branch: nil, isMain: result.isEmpty, isLocked: false, isPrunable: false)
            for line in block.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts.first {
                case "worktree": wt.path = parts.count > 1 ? parts[1] : ""
                case "HEAD": wt.head = parts.count > 1 ? parts[1] : nil
                case "branch":
                    wt.branch = parts.count > 1 ? parts[1].replacingOccurrences(of: "refs/heads/", with: "") : nil
                case "locked": wt.isLocked = true
                case "prunable": wt.isPrunable = true
                default: break
                }
            }
            if !wt.path.isEmpty { result.append(wt) }
        }
        return result
    }
}

/// Compares paths after resolving symlinks (`/tmp` vs `/private/tmp`).
func samePath(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
}
