import BPCore
import BPSessions
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
                "instructions": "Bullpen manages git worktrees, each with its own terminal and coding agent. Use list_worktrees first; refer to worktrees by branch name. current_worktree tells you which one you are in. Work only in your own worktree: when a task also needs changes on another branch or in another project (e.g. the backend in another repository), delegate them with create_worktree and a complete task, so another agent does them in parallel; never edit files in another worktree's folder yourself. Then keep going with your part; the other agent reports back to your mailbox (read_inbox), or wait_for_worktree until it stops, or use ask_worktree to send a message and get the answer back. send_message types into the other agent's terminal right away; post_message leaves it in its mailbox and Bullpen delivers it when that agent finishes its turn (use it while the other agent is busy, or to tell the user something with to=\"user\"). Each project has a shared task board: create_task, list_tasks, claim_task before starting one, complete_task with its result (the creator gets it by mailbox). Check read_inbox when you start and between tasks. Only remove worktrees the user asked you to remove.",
            ])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                if name.hasPrefix("browser_") { return reply(id: id, result: ["content": try await browser(name, args)]) }
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
        func number() throws -> Int {
            guard let value = args["number"] as? Int else { throw ControlError("Falta «number» (el número de la tarea, sin #).") }
            return value
        }
        switch name {
        case "list_projects":
            return try json(try service.projects().map { ["name": $0.name, "path": $0.path, "base": $0.defaultBaseRef ?? ""] })
        case "list_worktrees":
            return try json(try await service.worktrees(project: args["project"] as? String))
        case "create_worktree":
            // Delegating is the point: another agent works there, in parallel. Without `agent`
            // it is the caller's own (an empty worktree only with agent "none").
            let caller = try? service.current()
            let requested = (args["agent"] as? String)?.trimmingCharacters(in: .whitespaces)
            let agent = requested == "none" ? nil : (requested?.nilIfBlank ?? caller?.agent ?? "claude")
            var task = (args["task"] as? String)?.nilIfBlank
            if agent != nil, task == nil {
                throw ControlError("Falta «task»: lo que tiene que hacer el agente del nuevo worktree. Para un worktree vacío, sin agente, pasa agent \"none\".")
            }
            if let caller, let given = task {
                task = given + "\n\nTe lo ha encargado el agente de «\(caller.branch)» (\(caller.project)). Cuando termines, mándale el resultado (qué has hecho, rama y PR) con post_message a «\(caller.branch)»."
            }
            let wt = try await service.create(
                project: try string("project"), branch: try string("branch"), base: args["base"] as? String,
                agent: agent, model: args["model"] as? String, task: task
            )
            guard let agent = wt.agentProfileID else { return "Creado «\(wt.branch)» en \(wt.path), sin agente." }
            return "Creado «\(wt.branch)» en \(wt.path). Su agente (\(agent)) ya está trabajando en la tarea: no la hagas tú ni toques sus ficheros. Sigue con lo tuyo; te mandará el resultado a tu buzón (read_inbox), o espéralo con wait_for_worktree."
        case "send_message":
            try await service.send(try string("worktree"), text: try string("text"))
            return "Enviado."
        case "current_worktree":
            return try json(try service.current())
        case "wait_for_worktree":
            let states = (args["until"] as? [String]).map(Set.init) ?? ControlService.stopStates
            return try json(try await service.wait(try string("worktree"), until: states,
                                                   timeout: TimeInterval(args["timeout"] as? Int ?? 600)))
        case "ask_worktree":
            return try await service.ask(try string("worktree"), text: try string("text"),
                                         timeout: TimeInterval(args["timeout"] as? Int ?? 1800))
        case "read_terminal":
            return try service.readTerminal(try string("worktree"), lines: args["lines"] as? Int ?? 60)
        case "post_message":
            let message = try service.post(to: try string("to"), text: try string("text"))
            return message.toWorktree == nil
                ? "Enviado al usuario: lo verá en Bullpen con un aviso."
                : "En su buzón: se le entrega en cuanto termine su turno, sin interrumpirle."
        case "read_inbox":
            let messages = try service.readInbox()
            if messages.isEmpty { return "No tienes mensajes nuevos." }
            return messages.map { "[\($0.fromLabel)] \($0.text)" }.joined(separator: "\n\n")
        case "create_task":
            let task = try service.createTask(title: try string("title"), detail: args["detail"] as? String, project: args["project"] as? String)
            return "Tarea #\(task.number) creada en el tablero."
        case "list_tasks":
            let status = try (args["status"] as? String).map { raw in
                guard let status = AgentTask.Status(rawValue: raw) else { throw ControlError("Estado desconocido «\(raw)»: open, claimed o done.") }
                return status
            }
            let tasks = try service.tasks(project: args["project"] as? String, status: status)
            return try json(tasks.map { task in
                var row = ["number": "\(task.number)", "title": task.title, "status": task.status.rawValue, "createdBy": task.createdByLabel]
                row["detail"] = task.detail
                row["assignee"] = task.assigneeLabel
                row["result"] = task.result
                return row
            })
        case "claim_task":
            let task = try service.claimTask(try number(), project: args["project"] as? String)
            return "Tarea #\(task.number) «\(task.title)» es tuya.\(task.detail.map { "\n\n\($0)" } ?? "")"
        case "complete_task":
            let task = try service.completeTask(try number(), result: try string("result"), project: args["project"] as? String)
            return "Tarea #\(task.number) hecha. Quien la creó recibe el resultado en su buzón."
        case "remove_worktree":
            try await service.remove(try string("worktree"), force: args["force"] as? Bool ?? false)
            return "Eliminado (la rama se conserva)."
        default:
            throw ControlError("Herramienta desconocida: \(name)")
        }
    }

    /// Browser tools: text answers, and the screenshot as an image the model can see.
    func browser(_ name: String, _ args: [String: Any]) async throws -> [[String: Any]] {
        let action: BrowserRequest.Action = switch name {
        case "browser_open": .open
        case "browser_snapshot": .snapshot
        case "browser_screenshot": .screenshot
        case "browser_click": .click
        case "browser_type": .type
        case "browser_eval": .eval
        case "browser_console": .console
        default: throw ControlError("Herramienta desconocida: \(name)")
        }
        let response = try await service.browser(
            action, worktree: args["worktree"] as? String, url: args["url"] as? String, selector: args["selector"] as? String,
            text: args["text"] as? String, submit: args["submit"] as? Bool, script: args["script"] as? String
        )
        var content: [[String: Any]] = []
        if let image = response.image { content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/png"]) }
        if let text = response.text, !text.isEmpty { content.append(["type": "text", "text": text]) }
        return content.isEmpty ? [["type": "text", "text": "Hecho."]] : content
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
        tool("create_worktree", "Delegate work on another branch (of this or another project) to a new agent working in parallel: creates the worktree and starts its own agent with the task. Don't do that work yourself.",
             ["project": ["type": "string"], "branch": ["type": "string"], "base": ["type": "string", "description": "Base ref (default: project's)"],
              "agent": ["type": "string", "description": "claude, codex, gemini, opencode, … (default: the same as yours; \"none\" for an empty worktree)"],
              "model": ["type": "string"],
              "task": ["type": "string", "description": "Everything the new agent needs to do the work on its own: goal, context, contracts with your side (endpoints, fields…), and how to verify it"]],
             ["project", "branch", "task"]),
        tool("send_message", "Send a message to the agent (or shell) running in a worktree's terminal.",
             ["worktree": ["type": "string", "description": "Branch name or id"], "text": ["type": "string"]], ["worktree", "text"]),
        tool("current_worktree", "The worktree you are running in (project, branch, path), if Bullpen started you.", [:], []),
        tool("wait_for_worktree", "Wait until another worktree's agent stops (done, needsYou, idle, error, dead) or reaches the given states. Uses Bullpen's status engine (hooks), not output silence.",
             ["worktree": ["type": "string"], "until": ["type": "array", "items": ["type": "string"], "description": "States to wait for (default: any stop)"],
              "timeout": ["type": "integer", "default": 600, "description": "Seconds"]], ["worktree"]),
        tool("ask_worktree", "Delegate to another worktree's agent: send it a message, wait until it finishes, and get its answer (its last message, or its terminal's last lines).",
             ["worktree": ["type": "string"], "text": ["type": "string"], "timeout": ["type": "integer", "default": 1800, "description": "Seconds"]],
             ["worktree", "text"]),
        tool("browser_open", "Open a page in the worktree's browser tab in Bullpen (by default the worktree's own URL: its dev server). Returns the title and URL.",
             ["url": ["type": "string", "description": "Absolute URL, or a path like /login on the worktree's URL"],
              "worktree": ["type": "string", "description": "Branch or id (default: yours)"]], []),
        tool("browser_snapshot", "The page in the worktree's browser: URL, title, visible text and its links, buttons and fields with CSS selectors.",
             ["worktree": ["type": "string"]], []),
        tool("browser_screenshot", "A screenshot of the page in the worktree's browser.", ["worktree": ["type": "string"]], []),
        tool("browser_click", "Click an element in the worktree's browser, by CSS selector or by its visible text.",
             ["selector": ["type": "string"], "text": ["type": "string", "description": "Visible text, when there is no selector"],
              "worktree": ["type": "string"]], []),
        tool("browser_type", "Type into a field in the worktree's browser (replaces its value), optionally submitting its form.",
             ["selector": ["type": "string"], "text": ["type": "string"], "submit": ["type": "boolean", "default": false],
              "worktree": ["type": "string"]], ["selector", "text"]),
        tool("browser_eval", "Run JavaScript in the page and return its result (as JSON text).",
             ["script": ["type": "string"], "worktree": ["type": "string"]], ["script"]),
        tool("browser_console", "Console messages and JavaScript errors from the page since it was opened.", ["worktree": ["type": "string"]], []),
        tool("post_message", "Leave a message in another worktree's mailbox (or the user's, with to=\"user\"). Unlike send_message it never interrupts: Bullpen types it in when that agent finishes its turn.",
             ["to": ["type": "string", "description": "Branch name or id, or \"user\""], "text": ["type": "string"]], ["to", "text"]),
        tool("read_inbox", "Your unread mailbox messages (from other agents, the user, or finished tasks you created). Marks them read.", [:], []),
        tool("create_task", "Add a task to the project's shared board for any agent to claim. Returns its number.",
             ["title": ["type": "string"], "detail": ["type": "string", "description": "What done looks like, files, constraints"],
              "project": ["type": "string", "description": "Default: yours"]], ["title"]),
        tool("list_tasks", "The project's task board: number, title, status (open, claimed, done), who has it and results.",
             ["status": ["type": "string", "enum": ["open", "claimed", "done"]], "project": ["type": "string"]], []),
        tool("claim_task", "Take an open task before working on it, so no other agent does it too. Fails if someone else has it.",
             ["number": ["type": "integer"], "project": ["type": "string"]], ["number"]),
        tool("complete_task", "Mark your task done with its result (what changed, branch, PR…); whoever created it gets it by mailbox.",
             ["number": ["type": "integer"], "result": ["type": "string"], "project": ["type": "string"]], ["number", "result"]),
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
