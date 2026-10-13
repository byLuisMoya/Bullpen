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

/// Stand-ins for real agents: tests must never launch the user's Claude Code or Codex.
let fakeA = AgentProfile(id: "fake-a", name: "Fake A", executable: "/bin/echo")
let fakeB = AgentProfile(id: "fake-b", name: "Fake B", executable: "/bin/echo")

@Suite(.serialized) struct RunTests {
    @Test func branchNamesPerVariant() {
        let names = Workspace.branchNames(base: "fix/login", variants: [
            .init(agent: .claude, model: "opus"), .init(agent: .codex), .init(agent: .claude, model: "sonnet"),
        ])
        #expect(names == ["fix/login-claude-1", "fix/login-codex", "fix/login-claude-2"])
    }

    @Test func fanOutCreatesOneWorktreePerAgentInTheSameRun() async throws {
        let f = try await Fixture.make(config: "")
        defer { f.server.stop() }
        let base = WorktreeRequest(project: f.project, branch: "feat", baseRef: "main", task: "Añade un saludo", sendInitialPrompt: false)
        let (run, worktrees) = try await f.workspace.createRun(base, variants: [.init(agent: fakeA), .init(agent: fakeB)])
        #expect(worktrees.map(\.branch) == ["feat-fake-a", "feat-fake-b"])
        #expect(worktrees.allSatisfy { $0.runID == run.id })
        #expect(try f.workspace.database.worktrees(inRun: run.id).count == 2)
        #expect(try f.workspace.database.run(id: run.id)?.task == "Añade un saludo")
        let sessions = try await f.workspace.connect().list()
        #expect(sessions.count == 2, "each agent got its own terminal")
    }

    @Test func fanOutNeedsTwoAgentsAndATask() async throws {
        let f = try await Fixture.make(config: "")
        defer { f.server.stop() }
        let base = WorktreeRequest(project: f.project, branch: "x", baseRef: "main", task: "t")
        await #expect(throws: WorkspaceError.self) { try await f.workspace.createRun(base, variants: [.init(agent: fakeA)]) }
        var noTask = base
        noTask.task = " "
        await #expect(throws: WorkspaceError.self) {
            try await f.workspace.createRun(noTask, variants: [.init(agent: fakeA), .init(agent: fakeB)])
        }
    }

    @Test func judgePromptIncludesVerificationAndFlagsTruncation() {
        let ok = CommandResult(command: "make test", exitCode: 0, output: "")
        let bad = CommandResult(command: "make test", exitCode: 1, output: "1 failure")
        let prompt = RunJudge.prompt(task: "Arregla X", candidates: [
            Candidate(branch: "a", agent: "Claude Code", diff: "+x", verify: [ok]),
            Candidate(branch: "b", agent: "Codex", diff: String(repeating: "y", count: RunJudge.diffBudget + 10), verify: [bad]),
            Candidate(branch: "c", agent: "Codex", diff: "", verify: nil),
        ])
        #expect(prompt.contains("`make test` → OK"))
        #expect(prompt.contains("FALLA (1)") && prompt.contains("1 failure"))
        #expect(prompt.contains("MUY LARGO"))
        #expect(prompt.contains("Verificación: no ejecutada.") && prompt.contains("Sin cambios."))
    }
}

@Suite struct WorktreeSourceTests {
    @Test func recognisesTicketKeysAndURLs() {
        #expect(WorktreeSource.ticketKey(in: "#1234") == "#1234")
        #expect(WorktreeSource.ticketKey(in: "1234") == "#1234")
        #expect(WorktreeSource.ticketKey(in: "fkpi-12") == "FKPI-12")
        #expect(WorktreeSource.ticketKey(in: "https://github.com/acme/app/issues/45") == "#45")
        #expect(WorktreeSource.ticketKey(in: "https://github.com/acme/app/pull/7/files") == "#7")
        #expect(WorktreeSource.ticketKey(in: "https://linear.app/acme/issue/fkpi-88/arreglar-login") == "FKPI-88")
        #expect(WorktreeSource.ticketKey(in: "feature/login") == nil)
        #expect(WorktreeSource.ticketKey(in: "arregla el login") == nil)
    }

    @Test func turnsTextIntoBranchNames() {
        #expect(WorktreeSource.branchName(from: "Arregla el timeout del login") == "arregla-timeout-login")
        #expect(WorktreeSource.branchName(from: "Añadir exportación a CSV") == "anadir-exportacion-csv")
        #expect(WorktreeSource.branchName(fromName: "feature/FKPI-12-x") == "feature/FKPI-12-x")
        #expect(WorktreeSource.branchName(fromName: "nueva pantalla de ajustes") == "nueva-pantalla-ajustes")
        #expect(WorktreeSource.localName("origin/feature/x") == "feature/x")
    }
}

/// The new-worktree flow end to end: the project's setup script, existing and remote branches.
@Suite(.serialized) struct CreateFlowTests {
    /// Stands in for an agent: leaves a file behind when it starts.
    static let fakeAgent = AgentProfile(id: "fake", name: "Fake", executable: "touch", arguments: ["agent-started"],
                                        prompt: .type, modelFlag: nil)
    static let config = """
    [setup]
    run = ["echo toml >> order.txt"]
    """

    @Test func projectScriptRunsAfterTomlSetupAndBeforeTheAgent() async throws {
        let f = try await Fixture.make(config: Self.config)
        defer { f.server.stop() }
        var project = f.project
        project.setupScript = "echo script >> order.txt\ncp \"$BULLPEN_PROJECT_PATH/.env\" copied.env\necho 'it''s fine' >> order.txt"
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: project, branch: "setup-ok", baseRef: "main", agent: Self.fakeAgent))
        let path = URL(fileURLWithPath: wt.path)
        let started = path.appendingPathComponent("agent-started")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(FileManager.default.fileExists(atPath: started.path))
        #expect(try String(contentsOf: path.appendingPathComponent("order.txt"), encoding: .utf8) == "toml\nscript\nits fine\n")
        #expect(try String(contentsOf: path.appendingPathComponent("copied.env"), encoding: .utf8) == "SECRET=42\n")
    }

    @Test func failingScriptKeepsTheAgentClosed() async throws {
        let f = try await Fixture.make(config: Self.config)
        defer { f.server.stop() }
        var project = f.project
        project.setupScript = "echo script >> order.txt\nfalse\necho never >> order.txt"
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: project, branch: "setup-fails", baseRef: "main", agent: Self.fakeAgent))
        let path = URL(fileURLWithPath: wt.path)
        #expect(await f.waitForFile(path.appendingPathComponent("order.txt")) != nil)
        try await Task.sleep(for: .seconds(1.5))
        #expect(try String(contentsOf: path.appendingPathComponent("order.txt"), encoding: .utf8) == "toml\nscript\n")
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("agent-started").path))
    }

    @Test func opensAnExistingLocalBranch() async throws {
        let f = try await Fixture.make(config: "")
        defer { f.server.stop() }
        let git = Git()
        try await git.run(["branch", "feature/existing"], in: f.repoDir)
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "feature/existing", baseRef: "main"))
        let head = try await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: wt.path))
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "feature/existing")
    }

    @Test func remoteBranchBecomesALocalBranchTrackingIt() async throws {
        let f = try await Fixture.make(config: "")
        defer { f.server.stop() }
        let git = Git()
        // A remote with a branch the local repo has never checked out.
        let remote = f.root.appendingPathComponent("remote.git")
        try await git.run(["clone", "-q", "--bare", f.repoDir.path, remote.path], in: f.root)
        try await git.run(["remote", "add", "origin", remote.path], in: f.repoDir)
        try await git.run(["push", "-q", "origin", "main:feature/remote-only"], in: f.repoDir)
        try await git.run(["fetch", "-q", "origin"], in: f.repoDir)

        let repo = try await Repository.open(at: f.repoDir)
        let remotes = try await repo.remoteBranches()
        #expect(remotes.contains("origin/feature/remote-only"))
        #expect(!remotes.contains { $0.hasSuffix("/HEAD") })

        let branch = WorktreeSource.localName("origin/feature/remote-only")
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: branch, baseRef: "origin/feature/remote-only"))
        let dir = URL(fileURLWithPath: wt.path)
        let head = try await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
        let upstream = try await git.run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: dir)
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "feature/remote-only")
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/feature/remote-only")
        #expect(try await repo.localBranches().contains("feature/remote-only"))
    }

    /// A PR's branch that this clone has never fetched: fetch it, then start from origin/<branch>.
    @Test func unfetchedPullRequestBranchCanBeFetchedAndOpened() async throws {
        let f = try await Fixture.make(config: "")
        defer { f.server.stop() }
        let git = Git()
        let remote = f.root.appendingPathComponent("remote.git")
        try await git.run(["clone", "-q", "--bare", f.repoDir.path, remote.path], in: f.root)
        try await git.run(["remote", "add", "origin", remote.path], in: f.repoDir)
        try await git.run(["fetch", "-q", "origin"], in: f.repoDir)
        try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: f.repoDir)
        // Someone else pushes a PR branch after our last fetch.
        try await git.run(["branch", "pr-branch", "main"], in: remote)

        let repo = try await Repository.open(at: f.repoDir)
        #expect(await repo.defaultRemoteBranch() == "main")
        #expect(try await !repo.remoteBranches().contains("origin/pr-branch"))
        try await repo.fetchBranch("pr-branch")
        #expect(try await repo.remoteBranches().contains("origin/pr-branch"))
        let wt = try await f.workspace.createWorktree(WorktreeRequest(project: f.project, branch: "pr-branch", baseRef: "origin/pr-branch"))
        let head = try await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: wt.path))
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "pr-branch")
    }
}
