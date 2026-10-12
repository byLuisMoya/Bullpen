@testable import BPGit
import Foundation
import Testing

@Suite struct OverlapTests {
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
