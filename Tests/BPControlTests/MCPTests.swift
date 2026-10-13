import BPAgents
@testable import BPControl
import BPCore
import BPGit
import BPPersistence
import BPSessions
import BPWorkspace
import Foundation
import Testing

@Suite(.serialized) struct MCPTests {
    struct Env {
        let mcp: MCPServer
        var service: ControlService { mcp.service }
        let server: SessionServer
        let repo: URL
    }

    func make() async throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bp-mcp-\(UUID().uuidString.prefix(8))")
        let repo = base.appendingPathComponent("api")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Git()
        try await git.run(["init", "-q", "-b", "main"], in: repo)
        try await git.run(["-c", "user.email=t@e.com", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try "[setup]\nrun = [\"echo prepared-by-setup\"]\n".write(to: repo.appendingPathComponent(".bullpen.toml"), atomically: true, encoding: .utf8)

        let socket = "/tmp/bp-mcp-\(UUID().uuidString.prefix(8)).sock"
        let logs = base.appendingPathComponent("logs")
        let server = SessionServer(socketPath: socket, logDirectory: logs, build: "test")
        server.idleExit = nil
        try server.start()
        let workspace = Workspace(
            database: try AppDatabase.inMemory(), connect: { try SessionClient.connect(socketPath: socket) },
            hooks: AgentHooks(bpPath: "/bin/true", claudeSettingsPath: base.appendingPathComponent("c.json").path),
            worktreeRoot: base.appendingPathComponent("worktrees"), claudeTrust: nil
        )
        let service = ControlService(workspace: workspace, logDirectory: logs)
        _ = try await service.addProject(path: repo.path)
        return Env(mcp: MCPServer(service: service, version: "test"), server: server, repo: repo)
    }

    func rpc(_ mcp: MCPServer, _ id: Int, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let reply = try #require(await mcp.handle(data))
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    func call(_ mcp: MCPServer, _ tool: String, _ args: [String: Any]) async throws -> (text: String, isError: Bool) {
        let r = try await rpc(mcp, 9, "tools/call", ["name": tool, "arguments": args])
        let result = try #require(r["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    @Test func handshakeAndToolList() async throws {
        let env = try await make()
        defer { env.server.stop() }
        let initResult = try #require(try await rpc(env.mcp, 1, "initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        #expect((initResult["serverInfo"] as? [String: Any])?["name"] as? String == "bullpen")
        #expect(await env.mcp.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        let tools = try #require((try await rpc(env.mcp, 2, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) ==
                ["list_projects", "list_worktrees", "create_worktree", "send_message", "read_terminal", "remove_worktree",
                 "current_worktree", "wait_for_worktree", "ask_worktree"])
        #expect((try await rpc(env.mcp, 3, "nope")["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func createMessageReadAndRemove() async throws {
        let env = try await make()
        defer { env.server.stop() }
        let created = try await call(env.mcp, "create_worktree", ["project": "api", "branch": "feature/mcp"])
        #expect(!created.isError, "\(created.text)")

        let list = try await call(env.mcp, "list_worktrees", [:])
        #expect(list.text.contains("\"branch\" : \"feature/mcp\""))

        // The setup ran in the worktree's terminal and its output is readable.
        var terminal = ""
        for _ in 0..<50 {
            terminal = try await call(env.mcp, "read_terminal", ["worktree": "feature/mcp"]).text
            if terminal.contains("prepared-by-setup") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(terminal.contains("prepared-by-setup"))
        #expect(!terminal.contains("\u{1B}"), "escape sequences are stripped")

        // Messages reach the shell left running after setup.
        try await Task.sleep(for: .milliseconds(800))
        #expect(try await call(env.mcp, "send_message", ["worktree": "feature/mcp", "text": "echo hola-desde-mcp > mcp.txt"]).isError == false)
        let wtPath = try #require(list.text.range(of: #""path" : "([^"]+)""#, options: .regularExpression).map {
            String(list.text[$0]).replacingOccurrences(of: "\"path\" : ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        })
        var echoed = ""
        for _ in 0..<50 {
            echoed = (try? String(contentsOfFile: wtPath + "/mcp.txt", encoding: .utf8)) ?? ""
            if !echoed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(echoed == "hola-desde-mcp\n")

        // Untracked work protects the worktree unless forced.
        let refused = try await call(env.mcp, "remove_worktree", ["worktree": "feature/mcp"])
        #expect(refused.isError && refused.text.contains("sin commitear"))
        #expect(try await call(env.mcp, "remove_worktree", ["worktree": "feature/mcp", "force": true]).isError == false)
        #expect(try await call(env.mcp, "list_worktrees", [:]).text == "[\n\n]")
    }

    @Test func errorsAreToolResultsNotCrashes() async throws {
        let env = try await make()
        defer { env.server.stop() }
        #expect(try await call(env.mcp, "create_worktree", ["project": "nope", "branch": "x"]).isError)
        #expect(try await call(env.mcp, "create_worktree", ["project": "api", "branch": "x", "agent": "skynet"]).text.contains("Agente desconocido"))
        #expect(try await call(env.mcp, "send_message", ["worktree": "ghost", "text": "hi"]).isError)
        #expect(try await call(env.mcp, "read_terminal", [:]).text.contains("Falta"))
    }

    @Test func stripsTerminalSequences() {
        #expect(ControlService.plainText("\u{1B}]0;title\u{07}\u{1B}[1;32mok\u{1B}[0m\r\nprogress 10%\rprogress 100%") == "ok\nprogress 100%")
    }

    // MARK: Coordination between agents

    @Test func waitAskAndKnowWhoIAm() async throws {
        let env = try await make()
        defer { env.server.stop() }
        let a = try await env.service.create(project: "api", branch: "coordina")
        let b = try await env.service.create(project: "api", branch: "ayudante")

        // Who am I: from the terminal's BULLPEN_SESSION_ID.
        #expect(try env.service.current(session: Workspace.sessionID(for: a)).branch == "coordina")
        #expect(throws: ControlError.self) { try env.service.current(session: nil) }

        // A plain terminal settles to idle once its output goes quiet.
        let settled = try await env.service.wait("ayudante", timeout: 20)
        #expect(ControlService.stopStates.contains(settled.state))

        // Ask: send, wait for it to finish, get the answer (the terminal, without a transcript).
        let answer = try await env.service.ask("ayudante", text: "echo respuesta-del-ayudante", timeout: 30)
        #expect(answer.contains("respuesta-del-ayudante"))

        // Messages from another worktree's agent are signed with its branch.
        try await env.service.send("ayudante", text: "echo firmado", from: Workspace.sessionID(for: a))
        try await Task.sleep(for: .seconds(1))
        #expect(try env.service.readTerminal("ayudante", lines: 20).contains("Mensaje del agente de «coordina»"))
        _ = b
    }

    @Test func waitGivesUpAfterTheTimeout() async throws {
        let env = try await make()
        defer { env.server.stop() }
        _ = try await env.service.create(project: "api", branch: "lento")
        await #expect(throws: ControlError.self) {
            try await env.service.wait("lento", until: ["never-happens"], timeout: 1, poll: .milliseconds(200))
        }
    }
}
