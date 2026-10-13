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
          {"number": 5, "headRefName": "a", "state": "CLOSED", "isDraft": false, "url": "https://x/5"},
          {"number": 4, "headRefName": "e", "state": "OPEN", "isDraft": false, "url": "https://x/4", "mergeable": "CONFLICTING"}
        ]
        """
        let prs = try GitHubCLI.parse(Data(json.utf8))
        #expect(prs["a"]?.number == 9 && prs["a"]?.state == .open && prs["a"]?.checks == .success)
        #expect(prs["b"]?.state == .draft && prs["b"]?.checks == PullRequest.Checks.none)
        #expect(prs["c"]?.state == .merged)
        #expect(prs["d"]?.state == .closed)
        #expect(prs["e"]?.hasConflicts == true && prs["a"]?.hasConflicts == false)
    }

    /// REST shapes (issues/…/comments, pulls/…/reviews, pulls/…/comments) as `gh api` returns them.
    @Test func parsesCommentsAndTellsBotsApart() throws {
        let inline = #"[{"id": 41, "user": {"login": "ana", "type": "User"}, "body": "Esto rompe el caché", "path": "src/a.php", "line": null, "original_line": 12, "in_reply_to_id": null, "html_url": "https://x/41"}]"#
        let conversation = #"[{"id": 7, "user": {"login": "linear-code[bot]", "type": "Bot"}, "body": "linkback", "html_url": "https://x/7"}]"#
        let reviews = #"[{"id": 3, "user": {"login": "ana", "type": "User"}, "body": "", "state": "APPROVED"}, {"id": 4, "user": null, "body": "ghost"}]"#
        let a = try GitHubCLI.parseComments(Data(inline.utf8), kind: .inline)
        #expect(a == [PullRequestComment(id: "inline:41", kind: .inline, author: "ana", body: "Esto rompe el caché",
                                         path: "src/a.php", line: 12, url: URL(string: "https://x/41"))])
        #expect(try GitHubCLI.parseComments(Data(conversation.utf8), kind: .conversation).first?.isBot == true)
        #expect(try GitHubCLI.parseComments(Data(reviews.utf8), kind: .review).isEmpty, "no words, no author: nothing to act on")
    }

    @Test func picksTheCommentsAnAgentShouldSee() {
        let comments = [
            PullRequestComment(id: "inline:1", kind: .inline, author: "ana", body: "a"),
            PullRequestComment(id: "conversation:2", kind: .conversation, author: "bot", isBot: true, body: "b"),
            PullRequestComment(id: "inline:3", kind: .inline, author: "Luis", body: "nota de revisión", path: "x.swift"),
            PullRequestComment(id: "inline:4", kind: .inline, author: "luis", body: "respuesta", isReply: true),
            PullRequestComment(id: "conversation:5", kind: .conversation, author: "luis", body: "Hecho en abc123"),
            PullRequestComment(id: "review:6", kind: .review, author: "ana", body: "Faltan tests"),
        ]
        #expect(PullRequestComment.forAgent(comments, me: "luis").map(\.id) == ["inline:1", "inline:3", "review:6"])
        #expect(PullRequestComment.forAgent(comments, me: nil).count == 5)

        let text = PullRequestComment.agentMessage([comments[0], comments[5]], pullRequest: 12)
        #expect(text.hasPrefix("Hay 2 comentarios nuevos en la PR #12"))
        #expect(text.contains("- @ana: a") && text.contains("- @ana (revisión): Faltan tests"))
        #expect(PullRequestComment.agentMessage([comments[2]], pullRequest: 1).contains("@Luis en x.swift: nota de revisión"))
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
