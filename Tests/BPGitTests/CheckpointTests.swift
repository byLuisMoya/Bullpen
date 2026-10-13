@testable import BPGit
import Foundation
import Testing

@Suite struct CheckpointTests {
    func write(_ text: String, _ name: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func savesOnlyWhenSomethingChangedAndListsNewestFirst() async throws {
        let (repo, dir) = try await makeRepo()
        let wt = UUID()
        let first = try #require(try await repo.createCheckpoint(of: wt, in: dir, message: "uno"))
        #expect(first.number == 1)
        #expect(try await repo.createCheckpoint(of: wt, in: dir, message: "igual") == nil)
        try write("nuevo\n", "notes.txt", in: dir)            // untracked counts too
        let second = try #require(try await repo.createCheckpoint(of: wt, in: dir, message: "dos"))
        #expect(try await repo.checkpoints(of: wt).map(\.number) == [2, 1])
        #expect(second.message == "dos")
        // Other worktrees keep their own list.
        #expect(try await repo.checkpoints(of: UUID()).isEmpty)
    }

    @Test func diffsSinceACheckpointIncludeUntrackedFiles() async throws {
        let (repo, dir) = try await makeRepo()
        let wt = UUID()
        let start = try #require(try await repo.createCheckpoint(of: wt, in: dir, message: "inicio"))
        try write("hola\n", "README.md", in: dir)
        try write("x\n", "new.txt", in: dir)
        let changes = try await repo.changes(in: dir, since: start)
        #expect(Set(changes.map(\.path)) == ["README.md", "new.txt"])
    }

    @Test func restoreBringsFilesBackAndCanBeUndone() async throws {
        let (repo, dir) = try await makeRepo()
        let git = Git()
        let wt = UUID()
        try write("staged\n", "staged.txt", in: dir)
        try await git.run(["add", "staged.txt"], in: dir)
        let headBefore = try await git.run(["rev-parse", "HEAD"], in: dir)
        let start = try #require(try await repo.createCheckpoint(of: wt, in: dir, message: "inicio"))

        // The agent edits, deletes and creates files after the checkpoint.
        try write("cambiado\n", "README.md", in: dir)
        try write("después\n", "later.txt", in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("staged.txt"))

        let safety = try #require(try await repo.restore(start, of: wt, in: dir))
        #expect(read("README.md", in: dir) == "hello\n")
        #expect(read("staged.txt", in: dir) == "staged\n")
        #expect(read("later.txt", in: dir) == nil)
        // Branch and index untouched.
        #expect(try await git.run(["rev-parse", "HEAD"], in: dir) == headBefore)
        #expect(try await git.run(["diff", "--cached", "--name-only"], in: dir).contains("staged.txt"))

        // The state before restoring was saved: going back to it undoes the restore.
        try await repo.restore(safety, of: wt, in: dir)
        #expect(read("README.md", in: dir) == "cambiado\n")
        #expect(read("later.txt", in: dir) == "después\n")
        #expect(read("staged.txt", in: dir) == nil)
    }

    @Test func deletingForgetsAWorktreesCheckpoints() async throws {
        let (repo, dir) = try await makeRepo()
        let wt = UUID()
        try await repo.createCheckpoint(of: wt, in: dir, message: "uno")
        try await repo.deleteCheckpoints(of: wt)
        #expect(try await repo.checkpoints(of: wt).isEmpty)
    }
}
