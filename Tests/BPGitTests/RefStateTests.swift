@testable import BPGit
import Foundation
import Testing

/// The status poll reads every ref at once; it must say the same as the one-by-one calls.
@Suite struct RefStateTests {
    @Test func matchesBranchSyncAndCheckpointsOneByOne() async throws {
        let (repo, dir) = try await makeRepo()
        let git = Git()
        let remote = dir.deletingLastPathComponent().appendingPathComponent("remote-\(UUID().uuidString).git")
        try await git.run(["init", "-q", "--bare", remote.path], in: dir)
        try await git.run(["remote", "add", "origin", remote.path], in: dir)
        try await git.run(["checkout", "-q", "-b", "feature"], in: dir)
        try await git.run(["push", "-q", "-u", "origin", "feature"], in: dir)
        try "x\n".write(to: dir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: dir)
        try await git.run(["commit", "-q", "-m", "x"], in: dir)
        try await git.run(["branch", "local-only"], in: dir)

        let wt = UUID(), other = UUID()
        try await repo.createCheckpoint(of: wt, in: dir, message: "uno")
        try "y\n".write(to: dir.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        try await repo.createCheckpoint(of: wt, in: dir, message: "dos")

        let state = try #require(await repo.refState())
        let counts = GitResultCache<[Int]>()
        for branch in ["feature", "local-only", "main", "missing"] {
            #expect(await repo.branchSync(branch, in: state, counts: counts) == (await repo.branchSync(branch)), "\(branch)")
        }
        #expect(state.checkpoints[wt] == (try await repo.checkpoints(of: wt).count))
        #expect(state.checkpoints[other] == nil)
    }

    @Test func cachesByKeyAndForgetsWhenFull() async {
        let cache = GitResultCache<Int>(limit: 2)
        var runs = 0
        #expect(await cache.value(for: "a") { runs += 1; return 1 } == 1)
        #expect(await cache.value(for: "a") { runs += 1; return 2 } == 1)
        #expect(runs == 1)
        _ = await cache.value(for: "b") { 2 }
        _ = await cache.value(for: "c") { 3 }
        #expect(await cache.value(for: "a") { runs += 1; return 4 } == 4)
        // A failure isn't remembered.
        #expect(await cache.value(for: "f") { nil } == nil)
        #expect(await cache.value(for: "f") { 5 } == 5)
    }
}
