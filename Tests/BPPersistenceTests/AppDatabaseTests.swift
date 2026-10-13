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
                             agentProfileID: "claude", agentModel: "opus", taskDescription: "Arregla el login", ports: ["web": 4100]))
        let wt = try #require(try db.offices().first?.worktrees.first)
        #expect(wt.ports == ["web": 4100])
        #expect(wt.agentProfileID == "claude" && wt.agentModel == "opus" && wt.taskDescription == "Arregla el login")
    }

    @Test func initialPromptRoundTrips() throws {
        let db = try AppDatabase.inMemory()
        try db.save(Project(name: "a", path: "/tmp/a", initialPrompt: "Lee CLAUDE.md"))
        #expect(try db.offices().first?.project.initialPrompt == "Lee CLAUDE.md")
    }
}

@Suite struct AutomationStorageTests {
    @Test func savesAndReadsAutomations() throws {
        let db = try AppDatabase.inMemory()
        let project = Project(name: "app", path: "/tmp/app-\(UUID().uuidString)")
        try db.save(project)
        var auto = Automation(name: "Deps", projectID: project.id, agentID: "codex", task: "Revisa", weekdays: [2, 4], hour: 8, minute: 30)
        try db.save(auto)
        let read = try #require(try db.automations().first)
        #expect(read.id == auto.id && read.weekdays == [2, 4] && read.hour == 8 && read.minute == 30 && read.agentID == "codex" && read.enabled)
        auto.lastRun = Date(timeIntervalSince1970: 1_800_000_000)
        try db.save(auto)
        #expect(try db.automations().first?.lastRun == auto.lastRun)
        try db.deleteAutomation(id: auto.id)
        #expect(try db.automations().isEmpty)
    }
}
