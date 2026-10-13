@testable import BPGit
import Foundation
import Testing

@Suite struct BranchStatusTests {
    @Test func tracksPushedAndAheadBehind() async throws {
        let (repo, dir) = try await makeRepo()
        let git = Git()
        let remote = dir.deletingLastPathComponent().appendingPathComponent("remote-\(UUID().uuidString).git")
        try await git.run(["init", "-q", "--bare", remote.path], in: dir)
        try await git.run(["remote", "add", "origin", remote.path], in: dir)
        try await git.run(["checkout", "-q", "-b", "feature"], in: dir)

        #expect(await repo.branchSync("feature") == BranchSync(isPushed: false))

        try await git.run(["push", "-q", "-u", "origin", "feature"], in: dir)
        #expect(await repo.branchSync("feature") == BranchSync(isPushed: true, ahead: 0, behind: 0))

        try "x\n".write(to: dir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: dir)
        try await git.run(["commit", "-q", "-m", "x"], in: dir)
        #expect(await repo.branchSync("feature") == BranchSync(isPushed: true, ahead: 1, behind: 0))
    }
}

@Suite struct PullRequestParsingTests {
    @Test func parsesStatesAndKeepsNewestPerBranch() throws {
        let json = """
        [
          {"number": 9, "headRefName": "a", "state": "OPEN", "isDraft": false, "url": "https://x/9",
           "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}]},
          {"number": 8, "headRefName": "b", "state": "OPEN", "isDraft": true, "url": "https://x/8", "statusCheckRollup": []},
          {"number": 7, "headRefName": "c", "state": "MERGED", "isDraft": false, "url": "https://x/7", "statusCheckRollup": null},
          {"number": 6, "headRefName": "d", "state": "CLOSED", "isDraft": false, "url": "https://x/6"},
          {"number": 5, "headRefName": "a", "state": "CLOSED", "isDraft": false, "url": "https://x/5"}
        ]
        """
        let prs = try GitHubCLI.parse(Data(json.utf8))
        #expect(prs["a"]?.number == 9 && prs["a"]?.state == .open && prs["a"]?.checks == .success)
        #expect(prs["b"]?.state == .draft && prs["b"]?.checks == PullRequest.Checks.none)
        #expect(prs["c"]?.state == .merged)
        #expect(prs["d"]?.state == .closed)
    }

    @Test func rollsUpChecks() {
        #expect(GitHubCLI.rollup([]) == .none)
        #expect(GitHubCLI.rollup([("COMPLETED", "SUCCESS", nil), ("COMPLETED", "SKIPPED", nil)]) == .success)
        #expect(GitHubCLI.rollup([("COMPLETED", "SUCCESS", nil), ("IN_PROGRESS", "", nil)]) == .pending)
        #expect(GitHubCLI.rollup([("QUEUED", "", nil), ("COMPLETED", "FAILURE", nil)]) == .failure)
        #expect(GitHubCLI.rollup([(nil, nil, "PENDING")]) == .pending)
        #expect(GitHubCLI.rollup([(nil, nil, "ERROR")]) == .failure)
    }
}

@Suite struct OpenPullRequestTests {
    @Test func parsesOpenPullRequests() throws {
        let json = #"[{"number":12,"title":"Arregla login","headRefName":"fix/login","url":"https://github.com/a/b/pull/12","isDraft":true}]"#
        let prs = try GitHubCLI.parseOpen(Data(json.utf8))
        #expect(prs == [OpenPullRequest(number: 12, title: "Arregla login", branch: "fix/login", url: URL(string: "https://github.com/a/b/pull/12"), isDraft: true)])
    }
}
