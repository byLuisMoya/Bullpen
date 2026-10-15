@testable import BPGit
import Foundation
import Testing

/// Creates a throwaway repository with one commit on `main`.
func makeRepo() async throws -> (Repository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bp-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let git = Git()
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    try await git.run(["config", "user.email", "test@example.com"], in: dir)
    try await git.run(["config", "user.name", "Test"], in: dir)
    try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try await git.run(["add", "."], in: dir)
    try await git.run(["commit", "-q", "-m", "init"], in: dir)
    return (try await Repository.open(at: dir), dir)
}

@Suite struct RepositoryTests {
    @Test func opensFromSubdirectoryAndReadsBranch() async throws {
        let (repo, dir) = try await makeRepo()
        let sub = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let reopened = try await Repository.open(at: sub)
        #expect(samePath(reopened.root.path, repo.root.path))
        #expect(try await repo.currentBranch() == "main")
    }

    @Test func rejectsNonRepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bp-no-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await #expect(throws: GitError.self) { try await Repository.open(at: dir) }
    }

    @Test func createsListsAndRemovesWorktree() async throws {
        let (repo, dir) = try await makeRepo()
        let wt = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/feature-x")
        try await repo.addWorktree(branch: "feature/x", at: wt, baseRef: "main")

        let list = try await repo.worktrees()
        #expect(list.count == 2)
        #expect(list[0].isMain)
        #expect(list[1].branch == "feature/x")
        #expect(try await repo.removalGuards(for: wt, baseRef: "main").isEmpty)

        try await repo.removeWorktree(at: wt, force: false)
        #expect(try await repo.worktrees().count == 1)
        #expect(await repo.branchExists("feature/x"), "branch is kept after removing the worktree")
    }

    @Test func guardsAgainstLosingWork() async throws {
        let (repo, dir) = try await makeRepo()
        let wt = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/work")
        try await repo.addWorktree(branch: "work", at: wt, baseRef: "main")
        let git = Git()
        try "change\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: wt)
        try await git.run(["commit", "-q", "-m", "work"], in: wt)
        try "dirty\n".write(to: wt.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let guards = try await repo.removalGuards(for: wt, baseRef: "main")
        #expect(guards.contains(.uncommittedChanges(count: 1)))
        #expect(guards.contains(.unpushedCommits(count: 1)))

        await #expect(throws: GitError.self) { try await repo.removeWorktree(at: wt, force: false) }
        try await repo.removeWorktree(at: wt, force: true)
        #expect(try await repo.worktrees().count == 1)
    }

    @Test func removesInBackgroundWithTheSameGuards() async throws {
        let (repo, dir) = try await makeRepo()
        let git = Git()
        let wt = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/bg")
        try await repo.addWorktree(branch: "bg", at: wt, baseRef: "main")

        // Untracked file: refused without force, and the folder stays where it was.
        try "new\n".write(to: wt.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) { try await repo.removeWorktree(at: wt, force: false, deleteInBackground: true) }
        #expect(FileManager.default.fileExists(atPath: wt.appendingPathComponent("new.txt").path))

        // Locked: git refuses even with the folder set aside, and it comes back.
        try FileManager.default.removeItem(at: wt.appendingPathComponent("new.txt"))
        try await git.run(["worktree", "lock", wt.path], in: repo.root)
        await #expect(throws: GitError.self) { try await repo.removeWorktree(at: wt, force: false, deleteInBackground: true) }
        #expect(FileManager.default.fileExists(atPath: wt.appendingPathComponent("README.md").path))
        try await git.run(["worktree", "unlock", wt.path], in: repo.root)

        // Clean: gone from git and from its place at once; the branch stays.
        try await repo.removeWorktree(at: wt, force: false, deleteInBackground: true)
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try await repo.worktrees().count == 1)
        #expect(await repo.branchExists("bg"))

        // Forced with changes: also gone.
        let dirty = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/dirty")
        try await repo.addWorktree(branch: "dirty", at: dirty, baseRef: "main")
        try "dirty\n".write(to: dirty.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await repo.removeWorktree(at: dirty, force: true, deleteInBackground: true)
        #expect(!FileManager.default.fileExists(atPath: dirty.path))
        #expect(try await repo.worktrees().count == 1)
    }

    @Test func validatesBranchNames() async throws {
        let (repo, _) = try await makeRepo()
        #expect(await repo.isValidBranchName("luis/fix-login"))
        #expect(await !repo.isValidBranchName("bad..name"))
        #expect(await !repo.isValidBranchName("with space"))
    }

    @Test func parsesPorcelainOutput() {
        let output = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /wt/a
        HEAD def
        detached
        locked reason here

        worktree /wt/b
        HEAD 123
        branch refs/heads/luis/b
        prunable gitdir file points to non-existent location

        """
        let wts = Repository.parseWorktrees(output)
        #expect(wts.map(\.path) == ["/repo", "/wt/a", "/wt/b"])
        #expect(wts[0].isMain && !wts[1].isMain)
        #expect(wts[1].branch == nil && wts[1].isLocked)
        #expect(wts[2].branch == "luis/b" && wts[2].isPrunable)
    }

    @Test func slugsPaths() {
        #expect(WorktreeLocation.slug("luis/Fix login!") == "luis-fix-login")
        #expect(WorktreeLocation.path(project: "web-app", branch: "a/b", root: URL(fileURLWithPath: "/r")).path == "/r/web-app/a-b")
    }
}
