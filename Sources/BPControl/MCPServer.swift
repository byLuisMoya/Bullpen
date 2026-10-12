import Foundation

/// `bp mcp`: a Model Context Protocol server over stdio so agents can drive Bullpen (PLAN §13):
/// list worktrees, start new ones with an agent, message them and read their terminals.
public struct MCPServer: Sendable {
    public var service: ControlService
    public var version: String

    public init(service: ControlService, version: String) {
        self.service = service
        self.version = version
    }

    /// Reads newline-delimited JSON-RPC from stdin and answers on stdout until EOF.
    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let reply = await handle(Data(line.utf8)) else { continue }
            FileHandle.standardOutput.write(reply + Data([0x0A]))
        }
    }

    /// One JSON-RPC message in, one reply out (nil for notifications).
    public func handle(_ data: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else {
            return reply(id: nil, error: (-32700, "Parse error"))
        }
        let id = message["id"]
        guard id != nil else { return nil }   // notifications (initialized, cancelled…) need no answer
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "bullpen", "version": version],
                "instructions": "Bullpen manages git worktrees, each with its own terminal and coding agent. Use list_worktrees first; refer to worktrees by branch name.",
            ])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(id: id, result: ["content": [["type": "text", "text": try await call(name, args)]]])
            } catch {
                return reply(id: id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return reply(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    func call(_ name: String, _ args: [String: Any]) async throws -> String {
        func string(_ key: String) throws -> String {
            guard let value = args[key] as? String, !value.isEmpty else { throw ControlError("Falta «\(key)».") }
            return value
        }
        switch name {
        case "list_projects":
            return try json(try service.projects().map { ["name": $0.name, "path": $0.path, "base": $0.defaultBaseRef ?? ""] })
        case "list_worktrees":
            return try json(try await service.worktrees(project: args["project"] as? String))
        case "create_worktree":
            let wt = try await service.create(
                project: try string("project"), branch: try string("branch"), base: args["base"] as? String,
                agent: args["agent"] as? String, model: args["model"] as? String, task: args["task"] as? String
            )
            return "Creado «\(wt.branch)» en \(wt.path)" + (wt.agentProfileID.map { " con \($0)" } ?? "")
        case "send_message":
            try await service.send(try string("worktree"), text: try string("text"))
            return "Enviado."
        case "read_terminal":
            return try service.readTerminal(try string("worktree"), lines: args["lines"] as? Int ?? 60)
        case "remove_worktree":
            try await service.remove(try string("worktree"), force: args["force"] as? Bool ?? false)
            return "Eliminado (la rama se conserva)."
        default:
            throw ControlError("Herramienta desconocida: \(name)")
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func json(_ value: [[String: String]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func reply(id: Any?, result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func reply(id: Any?, error: (Int, String)) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": error.0, "message": error.1]])
    }

    static var tools: [[String: Any]] { [
        tool("list_projects", "Projects (git repositories) registered in Bullpen.", [:], []),
        tool("list_worktrees", "Active worktrees with their agent and live state (working, needsYou, done…).",
             ["project": ["type": "string", "description": "Only this project"]], []),
        tool("create_worktree", "Create a worktree on a new branch and optionally start a coding agent in it with a task.",
             ["project": ["type": "string"], "branch": ["type": "string"], "base": ["type": "string", "description": "Base ref (default: project's)"],
              "agent": ["type": "string", "description": "claude, codex, gemini, opencode, …"], "model": ["type": "string"],
              "task": ["type": "string", "description": "What the agent should do"]], ["project", "branch"]),
        tool("send_message", "Send a message to the agent (or shell) running in a worktree's terminal.",
             ["worktree": ["type": "string", "description": "Branch name or id"], "text": ["type": "string"]], ["worktree", "text"]),
        tool("read_terminal", "Last lines printed in a worktree's terminal, as plain text.",
             ["worktree": ["type": "string"], "lines": ["type": "integer", "default": 60]], ["worktree"]),
        tool("remove_worktree", "Remove a worktree's folder (the branch is kept). Refuses if work would be lost unless force is true.",
             ["worktree": ["type": "string"], "force": ["type": "boolean", "default": false]], ["worktree"]),
    ] }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
}
