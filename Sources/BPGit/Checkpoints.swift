import Foundation

/// A snapshot of a worktree taken when its agent finished a turn (PLAN §11.3): a commit on a
/// private ref (`refs/bullpen/checkpoints/<worktree>/<n>`), including untracked files, that
/// never touches the branch, the index or the files.
public struct Checkpoint: Identifiable, Equatable, Sendable {
    public var commit: String
    public var number: Int
    public var date: Date
    public var message: String
    public var id: String { commit }

    public init(commit: String, number: Int, date: Date, message: String) {
        self.commit = commit
        self.number = number
        self.date = date
        self.message = message
    }
}

public extension Repository {
    static func checkpointPrefix(_ worktree: UUID) -> String { "refs/bullpen/checkpoints/\(worktree.uuidString)/" }

    /// Checkpoints of a worktree, newest first.
    func checkpoints(of worktree: UUID) async throws -> [Checkpoint] {
        let prefix = Self.checkpointPrefix(worktree)
        let output = try await git.run(["for-each-ref", "--sort=-refname", "--format=%(objectname)%09%(refname)%09%(creatordate:unix)%09%(subject)", prefix], in: root)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let number = Int(fields[1].dropFirst(prefix.count)), let unix = TimeInterval(fields[2]) else { return nil }
            return Checkpoint(commit: fields[0], number: number, date: Date(timeIntervalSince1970: unix), message: fields[3])
        }
    }

    /// Saves the worktree at `path` as a new checkpoint. Returns nil when nothing changed since
    /// the last one.
    @discardableResult
    func createCheckpoint(of worktree: UUID, in path: URL, message: String) async throws -> Checkpoint? {
        let tree = try await snapshotTree(in: path)
        let existing = try await checkpoints(of: worktree)
        if let last = existing.first, try await treeOf(last.commit) == tree { return nil }
        let head = try await git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        // Its own author: the user's git identity may be missing, and these commits are private.
        let identity = ["GIT_AUTHOR_NAME": "Bullpen", "GIT_AUTHOR_EMAIL": "bullpen@localhost",
                        "GIT_COMMITTER_NAME": "Bullpen", "GIT_COMMITTER_EMAIL": "bullpen@localhost"]
        let commit = try await git.run(["commit-tree", tree, "-p", head, "-m", message], in: path, environment: identity)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let number = (existing.first?.number ?? 0) + 1
        try await git.run(["update-ref", Self.checkpointPrefix(worktree) + String(format: "%04d", number), commit], in: root)
        return try await checkpoints(of: worktree).first { $0.commit == commit }
    }

    /// Everything that differs between `checkpoint` and the worktree now, untracked files included.
    func changes(in path: URL, since checkpoint: Checkpoint) async throws -> [FileDiff] {
        let now = try await snapshotTree(in: path)
        let text = try await git.run(["diff", "--no-color", "--no-ext-diff", "--find-renames", checkpoint.commit, now], in: path)
        return DiffParser.parse(text)
    }

    /// Puts the worktree's files back as they were at `checkpoint`. First saves the current state
    /// as a checkpoint, so the restore itself can be undone. Branch, HEAD and index stay as they are.
    @discardableResult
    func restore(_ checkpoint: Checkpoint, of worktree: UUID, in path: URL) async throws -> Checkpoint? {
        let safety = try await createCheckpoint(of: worktree, in: path, message: "Antes de volver al punto \(checkpoint.number)")
        let now = try await snapshotTree(in: path)
        // Files that appeared after the checkpoint (tracked or not) go away…
        let added = try await git.run(["diff", "--name-only", "-z", "--no-renames", "--diff-filter=A", checkpoint.commit, now], in: path)
        for file in added.split(separator: "\0") {
            try? FileManager.default.removeItem(at: path.appendingPathComponent(String(file)))
        }
        // …and everything else takes the checkpoint's content.
        try await git.run(["restore", "--source=\(checkpoint.commit)", "--worktree", "--", "."], in: path)
        return safety
    }

    /// Forgets a worktree's checkpoints (when it is removed).
    func deleteCheckpoints(of worktree: UUID) async throws {
        for checkpoint in try await checkpoints(of: worktree) {
            try await git.run(["update-ref", "-d", Self.checkpointPrefix(worktree) + String(format: "%04d", checkpoint.number)], in: root)
        }
    }

    /// The tree of the worktree's files right now (tracked and untracked, honouring .gitignore),
    /// built in a throwaway index so the real one is untouched.
    private func snapshotTree(in path: URL) async throws -> String {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("bullpen-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        // Start from a copy of the real index: its file stats let `add -A` skip unchanged files.
        // From `read-tree HEAD` it would read and hash every tracked file of the repository.
        let real = try? await git.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var seeded = real.map { (try? FileManager.default.copyItem(atPath: $0, toPath: index.path)) != nil } ?? false
        if seeded {
            // Files marked assume-unchanged or skip-worktree would be skipped by `add -A` (their
            // changes missed): with any of them, the old way. `ls-files -v` tags them h…/S.
            let tags = (try? await git.run(["ls-files", "-v"], in: path, environment: env)) ?? "?"
            seeded = !tags.split(separator: "\n").contains { $0.first.map { $0.isLowercase || $0 == "S" } ?? false }
                && tags != "?"
            if !seeded { try? FileManager.default.removeItem(at: index) }
        }
        if !seeded {
            try await git.run(["read-tree", "HEAD"], in: path, environment: env)
        }
        try await git.run(["add", "-A", "--", "."], in: path, environment: env)
        return try await git.run(["write-tree"], in: path, environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func treeOf(_ commit: String) async throws -> String {
        try await git.run(["rev-parse", "\(commit)^{tree}"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
