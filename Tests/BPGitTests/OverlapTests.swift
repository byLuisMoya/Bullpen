@testable import BPGit
import Foundation
import Testing

@Suite struct OverlapTests {
    /// A local `main` behind `origin/main`: the branch's own changes are counted from where it
    /// really started, not from the stale local tip.
    @Test func comparesWithTheUpstreamWhenTheLocalBaseIsBehind() async throws {
        let (repo, dir) = try await makeRepo()
        let git = Git()
        let remote = dir.deletingLastPathComponent().appendingPathComponent("remote-\(UUID().uuidString).git")
        try await git.run(["init", "-q", "--bare", remote.path], in: dir)
        try await git.run(["remote", "add", "origin", remote.path], in: dir)
        try await git.run(["push", "-q", "-u", "origin", "main"], in: dir)
        // Someone else's work lands on origin/main; the local main stays behind.
        try await git.run(["checkout", "-q", "-b", "other"], in: dir)
        try "theirs\n".write(to: dir.appendingPathComponent("theirs.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: dir)
        try await git.run(["commit", "-q", "-m", "theirs"], in: dir)
        try await git.run(["push", "-q", "origin", "other:main"], in: dir)
        try await git.run(["checkout", "-q", "main"], in: dir)
        try await git.run(["fetch", "-q", "origin"], in: dir)

        let wt = dir.deletingLastPathComponent().appendingPathComponent("eb-\(UUID().uuidString)/x")
        try await repo.addWorktree(branch: "x", at: wt, baseRef: "origin/main")
        try "mine\n".write(to: wt.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        #expect(await repo.effectiveBase("main", in: wt) == "origin/main")
        #expect(try await repo.changedPaths(in: wt, baseRef: "main") == ["mine.txt"])
        #expect(try await repo.removalGuards(for: wt, baseRef: "main").contains(.uncommittedChanges(count: 1)))
        // With no upstream of its own: the base's commits on origin don't count as unpushed.
        try await git.run(["branch", "--unset-upstream"], in: wt)
        #expect(try await !repo.removalGuards(for: wt, baseRef: "main").contains { if case .unpushedCommits = $0 { true } else { false } })
        try "x\n".write(to: wt.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: wt)
        try await git.run(["commit", "-q", "-m", "mine"], in: wt)
        #expect(try await repo.removalGuards(for: wt, baseRef: "main").contains(.unpushedCommits(count: 1)))
    }

    @Test func detectsSharedFilesAndRealConflicts() async throws {
        let (repo, dir) = try await makeRepo()
        let git = Git()
        let base = dir.deletingLastPathComponent().appendingPathComponent("ov-\(UUID().uuidString)")
        func commit(_ wt: URL, _ file: String, _ text: String) async throws {
            try text.write(to: wt.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await git.run(["add", "."], in: wt)
            try await git.run(["commit", "-q", "-m", file], in: wt)
        }
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b"), c = base.appendingPathComponent("c")
        try await repo.addWorktree(branch: "a", at: a, baseRef: "main")
        try await repo.addWorktree(branch: "b", at: b, baseRef: "main")
        try await repo.addWorktree(branch: "c", at: c, baseRef: "main")
        try await commit(a, "README.md", "hello from a\n")      // a and b edit the same line: conflict
        try await commit(b, "README.md", "hello from b\n")
        try "dirty\n".write(to: c.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)  // c only uncommitted

        let report = await repo.overlapReport([("a", a, "main"), ("b", b, "main"), ("c", c, "main")])
        #expect(report.conflicts["a"]?["b"] == ["README.md"])
        #expect(report.conflicts["b"]?["a"] == ["README.md"])
        #expect(report.conflicts["c"] == nil, "uncommitted work cannot conflict in merge-tree")
        #expect(report.overlaps["c"]?["a"] == ["README.md"])
        #expect(try await repo.mergeConflicts("a", "c").isEmpty)
    }
}
