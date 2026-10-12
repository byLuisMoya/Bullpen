import Foundation

/// A worktree's changes against its base, parsed from unified diff (PLAN §11.1).
public struct FileDiff: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case added = "A", modified = "M", deleted = "D", renamed = "R" }

    public var path: String
    public var oldPath: String?
    public var status: Status
    public var hunks: [Hunk]
    public var isBinary: Bool
    public var id: String { path }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}

public struct Hunk: Equatable, Sendable {
    public var header: String
    public var lines: [DiffLine]
}

public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case context, added, removed }
    public var kind: Kind
    public var text: String
    /// Line number in the old file (context/removed) and in the new file (context/added).
    public var oldNumber: Int?
    public var newNumber: Int?
    public var id: String { "\(oldNumber ?? -1):\(newNumber ?? -1):\(kind)" }
}

public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldLine = 0, newLine = 0

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                flushFile()
                // diff --git a/x b/y
                let parts = raw.dropFirst("diff --git ".count).components(separatedBy: " b/")
                let path = parts.count > 1 ? parts.last! : String(raw.split(separator: " ").last ?? "")
                current = FileDiff(path: path, oldPath: nil, status: .modified, hunks: [], isBinary: false)
            } else if current != nil, hunk == nil || raw.hasPrefix("@@") || raw.hasPrefix("new file") || raw.hasPrefix("deleted file") {
                if raw.hasPrefix("new file mode") { current?.status = .added }
                else if raw.hasPrefix("deleted file mode") { current?.status = .deleted }
                else if raw.hasPrefix("rename from ") { current?.status = .renamed; current?.oldPath = String(raw.dropFirst("rename from ".count)) }
                else if raw.hasPrefix("rename to ") { current?.path = String(raw.dropFirst("rename to ".count)) }
                else if raw.hasPrefix("Binary files ") { current?.isBinary = true }
                else if raw.hasPrefix("+++ "), raw != "+++ /dev/null" { current?.path = String(raw.dropFirst(raw.hasPrefix("+++ b/") ? 6 : 4)) }
                else if raw.hasPrefix("@@") {
                    flushHunk()
                    (oldLine, newLine) = hunkStarts(raw)
                    hunk = Hunk(header: raw, lines: [])
                }
            } else if hunk != nil {
                if raw.hasPrefix("+") {
                    hunk?.lines.append(DiffLine(kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newLine))
                    newLine += 1
                } else if raw.hasPrefix("-") {
                    hunk?.lines.append(DiffLine(kind: .removed, text: String(raw.dropFirst()), oldNumber: oldLine, newNumber: nil))
                    oldLine += 1
                } else if raw.hasPrefix(" ") {
                    hunk?.lines.append(DiffLine(kind: .context, text: String(raw.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1
                    newLine += 1
                }
                // "\ No newline at end of file" and empty trailing lines are ignored.
            }
        }
        flushFile()
        return files
    }

    /// `@@ -12,5 +14,7 @@` → (12, 14)
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ token: Substring?) -> Int {
            guard let token else { return 1 }
            return Int(token.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
        return (start(parts.dropFirst().first), start(parts.dropFirst(2).first))
    }
}

public extension Repository {
    /// Everything that differs from `baseRef` in the worktree at `path`: commits since the merge
    /// base plus uncommitted and untracked files (without touching the index).
    func changes(in path: URL, baseRef: String) async throws -> [FileDiff] {
        var text = try await git.run(["diff", "--no-color", "--no-ext-diff", "--find-renames", "--merge-base", baseRef], in: path)
        let untracked = try await git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: path)
            .split(separator: "\0").map(String.init)
        for file in untracked {
            // `git diff --no-index` exits 1 when files differ, which is always the case here.
            if let patch = try? await git.runAllowingDifferences(["diff", "--no-color", "--no-index", "--", "/dev/null", file], in: path) {
                text += "\n" + patch
            }
        }
        return DiffParser.parse(text)
    }

    /// Commits on the worktree's branch that are not in `baseRef` (newest first), as one-line summaries.
    func commitSummaries(in path: URL, baseRef: String) async throws -> [String] {
        try await git.run(["log", "--format=%s", "\(baseRef)..HEAD"], in: path)
            .split(separator: "\n").map(String.init)
    }

    func push(branch: String, from path: URL, remote: String = "origin") async throws {
        try await git.run(["push", "-u", remote, branch], in: path)
    }
}

extension Git {
    /// Like `run`, but exit status 1 still returns stdout (diff tools use it for "differences found").
    func runAllowingDifferences(_ arguments: [String], in directory: URL) async throws -> String {
        do {
            return try await run(arguments, in: directory)
        } catch let error as GitError where error.status == 1 {
            return error.stdout
        }
    }
}

public extension Repository {
    /// Files of the worktree that git tracks or would track (respects .gitignore), sorted.
    func listFiles(in path: URL) async throws -> [String] {
        let output = try await git.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: path)
        return Array(Set(output.split(separator: "\0").map(String.init))).sorted()
    }
}
