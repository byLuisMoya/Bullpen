@testable import BPGit
import Foundation
import Testing

@Suite struct DiffTests {
    @Test func parsesHunksWithLineNumbers() {
        let text = """
        diff --git a/src/a.swift b/src/a.swift
        index 111..222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -10,4 +10,5 @@ func x() {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        \\ No newline at end of file
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hola
        """
        let files = DiffParser.parse(text)
        #expect(files.map(\.path) == ["src/a.swift", "new.txt"])
        let lines = files[0].hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(lines[1].oldNumber == 11 && lines[1].newNumber == nil)
        #expect(lines[3].newNumber == 12)
        #expect(lines[4].oldNumber == 12 && lines[4].newNumber == 13)
        #expect(files[0].additions == 2 && files[0].deletions == 1)
        #expect(files[1].status == .added && files[1].hunks[0].lines[0].newNumber == 1)
    }

    @Test func worktreeChangesIncludeCommittedUncommittedAndUntracked() async throws {
        let (repo, dir) = try await makeRepo()
        let wt = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/review")
        try await repo.addWorktree(branch: "review", at: wt, baseRef: "main")
        let git = Git()
        try "committed\n".write(to: wt.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: wt)
        try await git.run(["commit", "-q", "-m", "Add c"], in: wt)
        try "hello\nchanged\n".write(to: wt.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: wt.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let changes = try await repo.changes(in: wt, baseRef: "main")
        #expect(Set(changes.map(\.path)) == ["c.txt", "README.md", "untracked.txt"])
        #expect(changes.first { $0.path == "untracked.txt" }?.status == .added)
        #expect(try await repo.commitSummaries(in: wt, baseRef: "main") == ["Add c"])
        // Reading changes must not stage anything.
        #expect(try await git.run(["diff", "--cached", "--name-only"], in: wt).isEmpty)
    }
}

@Suite struct ListFilesTests {
    @Test func listsTrackedAndNewFilesButNotIgnored() async throws {
        let (repo, dir) = try await makeRepo()
        try "secret\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try ".env\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("src/new.swift"), atomically: true, encoding: .utf8)
        #expect(try await repo.listFiles(in: dir) == [".gitignore", "README.md", "src/new.swift"])
    }
}
