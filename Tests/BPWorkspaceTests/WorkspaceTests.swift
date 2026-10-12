import BPAgents
import BPCore
import BPGit
import BPPersistence
import BPSessions
import BPEnv
@testable import BPWorkspace
import Foundation
import Testing

/// Repo with `.bullpen.toml`, an in-process bpd and an in-memory database.
struct Fixture {
    let repoDir: URL
    let root: URL
    let server: SessionServer
    let workspace: Workspace
    let project: Project

    static func make(config: String) async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bp-ws-\(UUID().uuidString.prefix(8))")
        let repoDir = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let git = Git()
        try await git.run(["init", "-q", "-b", "main"], in: repoDir)
        try await git.run(["config", "user.email", "t@example.com"], in: repoDir)
        try await git.run(["config", "user.name", "T"], in: repoDir)
        try config.write(to: repoDir.appendingPathComponent(".bullpen.toml"), atomically: true, encoding: .utf8)
        try "node_modules\n.env\n".write(to: repoDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."], in: repoDir)
        try await git.run(["commit", "-q", "-m", "init"], in: repoDir)
        // Ignored files that exist only in the main checkout.
        try "SECRET=42\n".write(to: repoDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("node_modules/lib"), withIntermediateDirectories: true)
        try "module".write(to: repoDir.appendingPathComponent("node_modules/lib/index.js"), atomically: true, encoding: .utf8)

        let socket = "/tmp/bp-ws-\(UUID().uuidString.prefix(8)).sock"
        let server = SessionServer(socketPath: socket, logDirectory: base.appendingPathComponent("logs"), build: "test")
        server.idleExit = nil
        try server.start()
        let db = try AppDatabase.inMemory()
        let project = Project(name: "app", path: repoDir.path, defaultBaseRef: "main", initialPrompt: "Proyecto {{project.name}}.")
        try db.save(project)
        let workspace = Workspace(
            database: db, connect: { try SessionClient.connect(socketPath: socket) },
            hooks: AgentHooks(bpPath: "/bin/true", claudeSettingsPath: base.appendingPathComponent("claude.json").path),
            worktreeRoot: base.appendingPathComponent("worktrees"), claudeTrust: nil
        )
        return Fixture(repoDir: repoDir, root: base, server: server, workspace: workspace, project: project)
    }

    func waitForFile(_ url: URL, timeout: Double = 10) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

@Suite(.serialized) struct WorkspaceTests {
    static let config = """
    [setup]
    copy = [".env"]
    clone = ["node_modules"]
    run = ["echo \\"prepared on $PORT\\" > setup.txt"]

    [env]
    PORT = "{{port:web}}"
    DATABASE_URL = "postgres://localhost/app_{{worktree.slug}}"

    [teardown]
    run = ["echo \\"bye $DATABASE_URL\\" > \\"$TEARDOWN_MARK\\""]

    [prompt]
    default = "Rama {{worktree.branch}}."
    """

    @Test func createsPreparesAndStartsTheWorktree() async throws {
        let f = try await Fixture.make(config: Self.config)
        defer { f.server.stop() }
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "luis/fix-login", baseRef: "main"))

        let path = URL(fileURLWithPath: wt.path)
        #expect(path.path.hasSuffix("worktrees/app/luis-fix-login"))
        let port = try #require(wt.ports?["web"])
        #expect((4100...4999).contains(port))
        // Copied and cloned from the main checkout.
        #expect(try String(contentsOf: path.appendingPathComponent(".env"), encoding: .utf8) == "SECRET=42\n")
        #expect(try String(contentsOf: path.appendingPathComponent("node_modules/lib/index.js"), encoding: .utf8) == "module")
        // [setup] ran in the worktree's terminal with the worktree's environment.
        #expect(await f.waitForFile(path.appendingPathComponent("setup.txt")) == "prepared on \(port)\n")
        // Saved, and the session is there.
        #expect(try f.workspace.database.offices().first?.worktrees.map(\.branch) == ["luis/fix-login"])
        let client = try await f.workspace.connect()
        #expect(try await client.list().contains { $0.id == Workspace.sessionID(for: wt) })
        client.close()
    }

    @Test func secondWorktreeGetsADifferentPort() async throws {
        let f = try await Fixture.make(config: Self.config)
        defer { f.server.stop() }
        let a = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "a", baseRef: "main"))
        let b = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "b", baseRef: "main"))
        #expect(a.ports?["web"] != b.ports?["web"])
    }

    @Test func removalRunsTeardownAndArchives() async throws {
        let f = try await Fixture.make(config: Self.config)
        defer { f.server.stop() }
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "feature/x", baseRef: "main"))
        _ = await f.waitForFile(URL(fileURLWithPath: wt.path).appendingPathComponent("setup.txt"))
        let mark = f.root.appendingPathComponent("teardown.txt")
        setenv("TEARDOWN_MARK", mark.path, 1)
        try await f.workspace.removeWorktree(wt, in: f.project, force: true)

        #expect(try String(contentsOf: mark, encoding: .utf8) == "bye postgres://localhost/app_feature-x\n")
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try f.workspace.database.offices().first?.worktrees.isEmpty == true)
        let client = try await f.workspace.connect()
        #expect(try await client.list().isEmpty)
        client.close()
    }

    @Test func invalidInputLeavesNothingBehind() async throws {
        let f = try await Fixture.make(config: "[env]\nX = \"{{nope}}\"\n[prompt]\ndefault = \"{{ticket.id}}\"")
        defer { f.server.stop() }
        await #expect(throws: WorkspaceError.self) {
            try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "bad..name", baseRef: "main"))
        }
        // Unknown prompt variable with an agent: rejected before git is touched.
        await #expect(throws: PromptError.self) {
            try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "ok", baseRef: "main", agent: .claude))
        }
        // Unknown variable in [env], even without an agent.
        await #expect(throws: (any Error).self) {
            try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "ok", baseRef: "main"))
        }
        let repo = try await Repository.open(at: f.repoDir)
        #expect(try await repo.worktrees().count == 1)
    }

    @Test func promptOrderIsGlobalRepoProjectTask() throws {
        var config = BullpenConfig()
        config.prompt = "Repo: rama {{worktree.branch}}."
        config.agentPrompts = ["claude": "Solo para Claude."]
        let project = Project(name: "web", path: "/p", initialPrompt: "Proyecto {{project.name}}.")
        let request = WorktreeRequest(project: project, branch: "b", baseRef: "main", agent: .claude,
                                      task: "Haz X", globalPrompt: "Global.")
        let prompt = try Workspace.composePrompt(request, config: config, path: "/wt")
        #expect(prompt == "Global.\n\nRepo: rama b.\n\nSolo para Claude.\n\nProyecto web.\n\nHaz X")
    }
}
