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

    /// The remote's default branch (`origin/HEAD` → `main`), if the clone knows it.
    public func defaultRemoteBranch(remote: String = "origin") async -> String? {
        guard let ref = try? await git.run(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], in: root) else { return nil }
        let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasPrefix(remote + "/") ? String(name.dropFirst(remote.count + 1)) : nil
    }

    /// Fetches one branch so `origin/<branch>` exists locally (a PR branch never checked out).
    public func fetchBranch(_ branch: String, remote: String = "origin") async throws {
        try await git.run(["fetch", "-q", remote, "refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"], in: root)
    }

    /// Local branches, most recently committed first.
    public func localBranches() async throws -> [String] {
        try await refs("refs/heads")
    }

    /// Remote-tracking branches (`origin/x`), most recent first, without `origin/HEAD`.
    public func remoteBranches() async throws -> [String] {
        try await refs("refs/remotes").filter { !$0.hasSuffix("/HEAD") && $0.contains("/") }
    }

    private func refs(_ prefix: String) async throws -> [String] {
        try await git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", prefix], in: root)
            .split(separator: "\n").map(String.init)
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
    /// `deleteInBackground`: the folder (with its dependencies, tens of thousands of files and
    /// several seconds of disk work) is set aside at once and deleted afterwards at background
    /// priority, so git forgets it in a moment. Only for a process that stays alive (the app).
    public func removeWorktree(at path: URL, force: Bool, deleteInBackground: Bool = false) async throws {
        // Without force, git checks the folder: with it gone, check the same first…
        let clean = deleteInBackground && !force ? await isClean(path) : false
        if deleteInBackground, force || clean, let aside = Self.setAside(path) {
            // …and again once nothing can reach it by its path, for whatever was written in between
            // (submodules can't be read there: their links are relative; the first check covers them).
            // Something new: back in place, and git decides as usual.
            if !force {
                let late = try? await git.run(["status", "--porcelain", "--ignore-submodules=all"], in: aside)
                if late?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true {
                    try Self.putBack(aside, at: path)
                    return try await removeWorktree(at: path, force: false)
                }
            }
            do {
                try await git.run(["worktree", "remove"] + (force ? ["--force", "--force"] : []) + [path.path], in: root)
            } catch {
                // Locked, say: the folder goes back where it was.
                try Self.putBack(aside, at: path)
                throw error
            }
            Self.deleteLater(aside.deletingLastPathComponent())
            return
        }
        var args = ["worktree", "remove"]
        if force { args += ["--force", "--force"] }
        args.append(path.path)
        do {
            try await git.run(args, in: root)
        } catch let error as GitError where !force && error.stderr.contains("containing submodules") {
            // Git won't remove a worktree with submodules without --force, clean or not. Their
            // repositories go with it, so force only when no submodule has uncommitted changes
            // or commits that aren't on a remote.
            guard await !submodulesPending(path) else { throw error }
            try await git.run(["worktree", "remove", "--force", path.path], in: root)
        }
    }

    /// What `git worktree remove` without force lets go: nothing modified or untracked, in the
    /// worktree or its submodules, and no submodule commit that isn't on a remote.
    private func isClean(_ path: URL) async -> Bool {
        guard let status = try? await git.run(["status", "--porcelain", "--ignore-submodules=none"], in: path),
              status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await !submodulesPending(path)
    }

    /// Some submodule has uncommitted changes or commits that aren't on a remote (or can't be read).
    private func submodulesPending(_ path: URL) async -> Bool {
        let pending = try? await git.run(["submodule", "foreach", "--recursive", "--quiet",
                                          "git status --porcelain; git log --oneline -1 HEAD --not --remotes"], in: path)
        return pending?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
    }

    /// Undoes `setAside`. If it can't (something took its place meanwhile), says where it is
    /// rather than leaving it, unmentioned, in a folder macOS empties.
    static func putBack(_ aside: URL, at path: URL) throws {
        guard Darwin.rename(aside.path, path.path) == 0 else {
            throw GitError(arguments: ["worktree", "remove"], status: -1,
                           stderr: "No se pudo devolver el worktree a \(path.path); está en \(aside.path)")
        }
        try? FileManager.default.removeItem(at: aside.deletingLastPathComponent())
    }

    /// Moves the folder into a temporary one of its own volume (a rename: instant, never a copy).
    /// Returns its new place, or nil if it couldn't be moved.
    static func setAside(_ path: URL) -> URL? {
        guard let dir = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: path, create: true) else { return nil }
        let aside = dir.appendingPathComponent(path.lastPathComponent, isDirectory: true)
        guard Darwin.rename(path.path, aside.path) == 0 else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return aside
    }

    /// Background QoS: its disk work is throttled, so the rest of the app (and the Mac) keeps its pace.
    static func deleteLater(_ dir: URL) {
        DispatchQueue.global(qos: .background).async { try? FileManager.default.removeItem(at: dir) }
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
