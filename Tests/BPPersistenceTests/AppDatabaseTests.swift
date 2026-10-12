import BPCore
import BPPersistence
import Foundation
import Testing

@Suite struct AppDatabaseTests {
    @Test func officesListActiveWorktreesInBuildingOrder() throws {
        let db = try AppDatabase.inMemory()
        let a = Project(name: "a", path: "/tmp/a", sortIndex: 0)
        let b = Project(name: "b", path: "/tmp/b", sortIndex: 1)
        try db.save(b)
        try db.save(a)
        try db.save(Worktree(projectID: a.id, branch: "fix-1", path: "/tmp/wt/1", baseRef: "main"))
        try db.save(Worktree(
            projectID: a.id, branch: "old", path: "/tmp/wt/2", baseRef: "main", archivedAt: Date()
        ))

        let offices = try db.offices()
        #expect(offices.map(\.project.name) == ["a", "b"])
        #expect(offices[0].worktrees.map(\.branch) == ["fix-1"])
        #expect(offices[0].lighting == .singleDesk)
        #expect(offices[1].lighting == .off)
    }

    @Test func deletingProjectRemovesItsWorktrees() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "a", path: "/tmp/a")
        try db.save(p)
        try db.save(Worktree(projectID: p.id, branch: "x", path: "/tmp/wt/x", baseRef: "main"))
        try db.deleteProject(id: p.id)
        #expect(try db.offices().isEmpty)
    }

    @Test func agentFieldsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "a", path: "/tmp/a")
        try db.save(p)
        try db.save(Worktree(projectID: p.id, branch: "x", path: "/tmp/wt/x", baseRef: "main",
                             agentProfileID: "claude", agentModel: "opus", taskDescription: "Arregla el login"))
        let wt = try #require(try db.offices().first?.worktrees.first)
        #expect(wt.agentProfileID == "claude" && wt.agentModel == "opus" && wt.taskDescription == "Arregla el login")
    }

    @Test func initialPromptRoundTrips() throws {
        let db = try AppDatabase.inMemory()
        try db.save(Project(name: "a", path: "/tmp/a", initialPrompt: "Lee CLAUDE.md"))
        #expect(try db.offices().first?.project.initialPrompt == "Lee CLAUDE.md")
    }
}
