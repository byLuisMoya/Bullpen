@testable import BPIntegrations
import Foundation
import Testing

@Suite struct TicketTests {
    @Test func parsesGitHubIssues() throws {
        let json = #"[{"number":45,"title":"Fix login timeout!","body":"Steps…","url":"https://github.com/o/r/issues/45","labels":[{"name":"bug"}]}]"#
        let t = try #require(try GitHubIssues.parse(Data(json.utf8)).first)
        #expect(t.key == "#45" && t.labels == ["bug"] && t.source == .github)
        #expect(t.suggestedBranch == "45-fix-login-timeout")
        #expect(t.variables["ticket.description"] == "Steps…")
    }

    @Test func parsesLinearIssuesAndPrefersItsBranchName() throws {
        let data: [String: Any] = ["viewer": ["assignedIssues": ["nodes": [[
            "id": "uuid-1", "identifier": "FKPI-123", "title": "Añadir roles", "description": "Detalle",
            "url": "https://linear.app/x/issue/FKPI-123", "branchName": "luis/fkpi-123-anadir-roles",
            "state": ["name": "Todo"], "team": ["id": "team-1"], "labels": ["nodes": [["name": "backend"]]],
        ]]]]]
        let t = try #require(try LinearClient.parseIssues(data).first)
        #expect(t.key == "FKPI-123" && t.teamID == "team-1" && t.state == "Todo" && t.labels == ["backend"])
        #expect(t.suggestedBranch == "luis/fkpi-123-anadir-roles")
        #expect(t.variables["ticket.comments"] == "")
    }

    @Test func linearCommentsGoIntoThePromptOldestFirst() throws {
        let data: [String: Any] = ["viewer": ["assignedIssues": ["nodes": [[
            "id": "uuid-1", "identifier": "FKPI-7", "title": "Roles", "description": "Detalle",
            "comments": ["nodes": [
                ["body": "Usa la tabla nueva", "createdAt": "2026-10-02T10:00:00.000Z", "user": ["displayName": "ana"]],
                ["body": "Ojo con los permisos", "createdAt": "2026-10-01T09:00:00.000Z", "user": ["name": "Pepe"]],
                ["body": "  ", "createdAt": "2026-10-03T09:00:00.000Z", "botActor": ["name": "GitHub"]],
            ]],
        ]]]]]
        let t = try #require(try LinearClient.parseIssues(data).first)
        #expect(t.comments.map(\.author) == ["Pepe", "ana", "GitHub"])
        let text = t.variables["ticket.comments"] ?? ""
        #expect(text.contains("— Pepe (2026-10-01):\nOjo con los permisos\n\n— ana (2026-10-02):\nUsa la tabla nueva\n</comentarios>"))
        #expect(!text.contains("GitHub"))
    }

    @Test func gitHubIssueComments() throws {
        let json = #"[{"number":4,"title":"T","body":"B","url":"https://github.com/o/r/issues/4","comments":[{"author":{"login":"luis"},"body":"Reproducido","createdAt":"2026-10-01T09:00:00Z"}]}]"#
        let t = try #require(try GitHubIssues.parse(Data(json.utf8)).first)
        #expect(t.comments == [Ticket.Comment(author: "luis", body: "Reproducido", date: Date(timeIntervalSince1970: 1_790_845_200))])
    }

    @Test func picksWorkflowStates() {
        let states = [
            LinearClient.WorkflowState(id: "r", name: "In Review", type: "started", position: 3),
            LinearClient.WorkflowState(id: "p", name: "In Progress", type: "started", position: 2),
            LinearClient.WorkflowState(id: "t", name: "Todo", type: "unstarted", position: 1),
        ]
        #expect(LinearClient.state(in: states, matching: .inProgress)?.id == "p")
        #expect(LinearClient.state(in: states, matching: .inReview)?.id == "r")
        #expect(LinearClient.state(in: [states[2]], matching: .inReview) == nil)
    }
}

@Suite struct LinearLookupTests {
    @Test func identifiersFromURLsKeysAndNumbers() {
        #expect(LinearLookup.parse("https://linear.app/fitness-kpi/issue/FIT-3476/internal-accesses-mejoras", teams: ["FIT"])
            == LinearLookup(identifiers: ["FIT-3476"]))
        #expect(LinearLookup.parse(" fit-3477 ", teams: ["FIT"]) == LinearLookup(identifiers: ["FIT-3477"]))
        #expect(LinearLookup.parse("3477", teams: ["FIT", "IMP"])
            == LinearLookup(identifiers: ["FIT-3477", "IMP-3477"], searchTerm: "3477", number: "3477"))
        #expect(LinearLookup.parse("#12", teams: []) == LinearLookup(identifiers: [], searchTerm: "12", number: "12"))
        #expect(LinearLookup.parse("selector de chains", teams: ["FIT"]) == LinearLookup(searchTerm: "selector de chains"))
        #expect(LinearLookup.parse("ab", teams: ["FIT"]).isEmpty)
        #expect(LinearLookup.parse("https://github.com/o/r/issues/4", teams: ["FIT"]).isEmpty)
    }
}
