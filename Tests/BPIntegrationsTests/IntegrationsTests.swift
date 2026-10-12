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
