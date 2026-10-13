import BPAgents
import BPCore
import BPGit
import BPPersistence
import BPSessions
import BPWorkspace
import Foundation

/// A worktree as the CLI and MCP report it.
public struct WorktreeSummary: Codable, Equatable, Sendable {
    public var id: String
    public var project: String
    public var branch: String
    public var path: String
    public var baseRef: String
    public var agent: String?
    public var state: String
    public var detail: String?
    public var ticket: String?
}

public struct ControlError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Operations shared by `bp` and `bp mcp` (PLAN §13): the same logic the app uses.
public struct ControlService: Sendable {
    public var workspace: Workspace
    public var logDirectory: URL
    public var globalPrompt: String?

    public init(workspace: Workspace, logDirectory: URL = SessionProtocol.defaultLogDirectory, globalPrompt: String? = nil) {
        self.workspace = workspace
        self.logDirectory = logDirectory
        self.globalPrompt = globalPrompt
    }

    public func projects() throws -> [Project] { try workspace.database.offices().map(\.project) }

    public func addProject(path: String) async throws -> Project {
        try await workspace.addProject(at: URL(fileURLWithPath: path))
    }

    /// Forgets a project (its office). Refuses while it still has active worktrees.
    public func removeProject(name: String) throws {
        guard let office = try workspace.database.offices().first(where: { $0.project.name == name }) else {
            throw ControlError("No hay ningún proyecto «\(name)».")
        }
        guard office.worktrees.isEmpty else {
            throw ControlError("«\(name)» aún tiene \(office.worktrees.count) worktree(s) activo(s). Elimínalos antes.")
        }
        try workspace.database.deleteProject(id: office.project.id)
    }

    public func worktrees(project: String? = nil) async throws -> [WorktreeSummary] {
        _ = try? await workspace.syncExternalWorktrees()
        let sessions = (try? await workspace.connect().list()) ?? []
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return try workspace.database.offices()
            .filter { project == nil || $0.project.name == project }
            .flatMap { office in
                office.worktrees.map { wt in
                    let status = StatusEngine.status(for: byID[Workspace.sessionID(for: wt)], profile: AgentProfile.named(wt.agentProfileID))
                    return WorktreeSummary(
                        id: wt.id.uuidString, project: office.project.name, branch: wt.branch, path: wt.path,
                        baseRef: wt.baseRef, agent: wt.agentProfileID, state: status.state.rawValue,
                        detail: status.detail, ticket: wt.ticket?.key
                    )
                }
            }
    }

    /// Finds an active worktree by branch name or id.
    public func find(_ reference: String) throws -> (Worktree, Project) {
        for office in try workspace.database.offices() {
            if let wt = office.worktrees.first(where: { $0.branch == reference || $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame }) {
                return (wt, office.project)
            }
        }
        throw ControlError("No hay ningún worktree activo «\(reference)».")
    }

    public func create(project name: String, branch: String, base: String? = nil, agent: String? = nil,
                       model: String? = nil, task: String? = nil, initialPrompt: Bool = true) async throws -> Worktree {
        guard let project = try projects().first(where: { $0.name == name }) else {
            throw ControlError("No hay ningún proyecto «\(name)». Añádelo con bp project add <ruta>.")
        }
        var profile: AgentProfile?
        if let agent {
            guard let found = AgentProfile.named(agent) else {
                throw ControlError("Agente desconocido «\(agent)». Disponibles: \(AgentProfile.all.map(\.id).joined(separator: ", ")).")
            }
            profile = found
        }
        var request = WorktreeRequest(
            project: project, branch: branch, baseRef: base ?? project.defaultBaseRef ?? "main",
            agent: profile, model: model, task: task, globalPrompt: globalPrompt, sendInitialPrompt: initialPrompt
        )
        request.awaitTypedPrompt = true
        return try await workspace.createWorktree(request)
    }

    /// Refuses to lose work unless `force`: uncommitted changes, unpushed commits, a locked worktree.
    public func remove(_ reference: String, force: Bool) async throws {
        let (wt, project) = try find(reference)
        if !force {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            let guards = try await repo.removalGuards(for: URL(fileURLWithPath: wt.path), baseRef: wt.baseRef)
            if !guards.isEmpty {
                throw ControlError("«\(wt.branch)» tiene trabajo que se perdería (\(guards.map(Self.describe).joined(separator: "; "))). Usa force para eliminarlo igualmente.")
            }
        }
        try await workspace.removeWorktree(wt, in: project, force: force)
    }

    /// Types `text` into the worktree's agent. Sent from another worktree's agent, it is signed
    /// with that worktree's branch so the receiver knows who is asking.
    public func send(_ reference: String, text: String, from sender: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) async throws {
        let (wt, _) = try find(reference)
        let client = try await workspace.connect()
        let id = Workspace.sessionID(for: wt)
        guard try await client.list().contains(where: { $0.id == id && $0.isRunning }) else {
            throw ControlError("«\(wt.branch)» no tiene una terminal en marcha.")
        }
        var message = text
        if let sender, sender != id, let from = try? current(session: sender) {
            message = "[Mensaje del agente de «\(from.branch)» (Bullpen)] " + text
        }
        try await client.sendMessage(id, message)
    }

    /// The worktree this process runs in (its terminal's `BULLPEN_SESSION_ID`).
    public func current(session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> WorktreeSummary {
        guard let session, session.hasPrefix("wt-") else {
            throw ControlError("Este proceso no corre en la terminal de ningún worktree de Bullpen.")
        }
        // `wt-<uuid>`, or `wt-<uuid>-t2` for an extra terminal tab of the same worktree.
        let (wt, project) = try find(String(session.dropFirst(3).prefix(36)))
        return WorktreeSummary(id: wt.id.uuidString, project: project.name, branch: wt.branch, path: wt.path,
                               baseRef: wt.baseRef, agent: wt.agentProfileID, state: "", detail: nil, ticket: wt.ticket?.key)
    }

    // MARK: Browser

    /// Drives the worktree's browser tab in the app (the given worktree, or the caller's own).
    public func browser(_ action: BrowserRequest.Action, worktree reference: String?, url: String? = nil, selector: String? = nil,
                        text: String? = nil, submit: Bool? = nil, script: String? = nil,
                        bridge: String = BrowserBridge.socketPath) async throws -> BrowserResponse {
        let (wt, project): (Worktree, Project)
        if let reference, !reference.isEmpty {
            (wt, project) = try find(reference)
        } else {
            (wt, project) = try find(try current().id)
        }
        let home = try workspace.browserURL(for: wt, in: project)
        let response = try await BrowserBridge.send(BrowserRequest(action: action, worktree: wt.id.uuidString, home: home, url: url,
                                                                   selector: selector, text: text, submit: submit, script: script),
                                                    socketPath: bridge)
        guard response.ok else { throw ControlError(response.text ?? "El navegador no pudo hacerlo.") }
        return response
    }

    /// States where an agent has stopped and is waiting for someone.
    public static let stopStates = Set([AgentState.done, .needsYou, .idle, .error, .dead].map(\.rawValue))

    /// Waits until the worktree's agent reaches one of `states` (by default: stopped for any
    /// reason), using the same status engine as the app, never "screen quiet for 3 s".
    @discardableResult
    public func wait(_ reference: String, until states: Set<String> = stopStates, timeout: TimeInterval = 600,
                     poll: Duration = .seconds(1)) async throws -> WorktreeSummary {
        let (wt, _) = try find(reference)
        let deadline = Date().addingTimeInterval(timeout)
        var last: WorktreeSummary?
        while true {
            last = try await worktrees().first { $0.id == wt.id.uuidString }
            if let last, states.contains(last.state) { return last }
            if Date() >= deadline {
                throw ControlError("«\(wt.branch)» sigue en «\(last?.state ?? "?")» tras \(Int(timeout)) s.")
            }
            try await Task.sleep(for: poll)
        }
    }

    /// Sends `text`, waits for the agent to take it and finish, and returns its answer: the last
    /// thing it said (from the Claude Code transcript), or its terminal's last lines.
    public func ask(_ reference: String, text: String, timeout: TimeInterval = 1800) async throws -> String {
        let (wt, _) = try find(reference)
        try await send(reference, text: text)
        // First it has to start on it; then it has to stop.
        _ = try? await wait(reference, until: [AgentState.working.rawValue, AgentState.thinking.rawValue], timeout: 30, poll: .milliseconds(300))
        let final = try await wait(reference, timeout: timeout)
        let answer = try await lastAnswer(of: wt) ?? readTerminal(reference, lines: 40)
        return "Estado: \(final.state)\(final.detail.map { " (\($0))" } ?? "")\n\n\(answer)"
    }

    private func lastAnswer(of worktree: Worktree) async throws -> String? {
        let client = try await workspace.connect()
        guard let path = try await client.list().first(where: { $0.id == Workspace.sessionID(for: worktree) })?.agentActivity?.transcriptPath,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return ActivityDigest.fromClaudeTranscript(text).lastMessage
    }

    /// The last `lines` lines the worktree's terminal printed, without escape sequences.
    public func readTerminal(_ reference: String, lines: Int = 60) throws -> String {
        let (wt, _) = try find(reference)
        let url = SessionProtocol.outputFile(session: Workspace.sessionID(for: wt), logDirectory: logDirectory)
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = Self.plainText(String(decoding: data.suffix(512 * 1024), as: UTF8.self))
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    static func describe(_ g: RemovalGuard) -> String {
        switch g {
        case let .uncommittedChanges(n): "\(n) fichero(s) sin commitear"
        case let .unpushedCommits(n): "\(n) commit(s) sin subir"
        case .locked: "bloqueado"
        }
    }

    /// Strips terminal control sequences and resolves carriage returns per line.
    static func plainText(_ s: String) -> String {
        let patterns = [#"\x1B\][^\x07\x1B]*(\x07|\x1B\\)"#, #"\x1B\[[0-?]*[ -/]*[@-~]"#, #"\x1B[@-Z\\-_]"#]
        var text = s
        for p in patterns { text = text.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        return text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }
}

// MARK: Coordination: mailbox and task board

public extension ControlService {
    /// Names that address the user instead of a worktree.
    static let userAliases: Set<String> = ["user", "usuario", "tú", "tu", "me"]

    /// The caller: its worktree and project, or nil when not run from one (the user, a script).
    private func caller(_ session: String?) -> (worktree: Worktree, project: Project)? {
        guard let summary = try? current(session: session) else { return nil }
        return try? find(summary.id)
    }

    /// Leaves `text` in a worktree's mailbox (or the user's): Bullpen types it in when that agent
    /// finishes its turn, so it never interrupts work in progress.
    @discardableResult
    func post(to reference: String, text: String,
              from session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> AgentMessage {
        let sender = caller(session)
        let message: AgentMessage
        if Self.userAliases.contains(reference.lowercased()) {
            guard let sender else { throw ControlError("Solo un agente de un worktree puede escribir al usuario.") }
            message = AgentMessage(projectID: sender.project.id, toWorktree: nil, fromWorktree: sender.worktree.id,
                                   fromLabel: sender.worktree.branch, text: text)
        } else {
            let (to, project) = try find(reference)
            if to.id == sender?.worktree.id { throw ControlError("Ese worktree eres tú.") }
            message = AgentMessage(projectID: project.id, toWorktree: to.id, fromWorktree: sender?.worktree.id,
                                   fromLabel: sender?.worktree.branch ?? "Tú", text: text)
        }
        try workspace.database.save(message)
        return message
    }

    /// The caller's unread messages, now marked read (they won't be typed in later).
    func readInbox(session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> [AgentMessage] {
        guard let me = caller(session) else { throw ControlError("Este proceso no corre en la terminal de ningún worktree de Bullpen.") }
        let unread = try workspace.database.messages(to: me.worktree.id, unreadOnly: true)
        try workspace.database.markMessages(unread.map(\.id), read: true)
        return unread
    }

    /// The project named, or the caller's.
    private func project(_ name: String?, session: String?) throws -> Project {
        if let name, !name.isEmpty {
            guard let project = try projects().first(where: { $0.name == name }) else { throw ControlError("No hay ningún proyecto «\(name)».") }
            return project
        }
        guard let mine = caller(session) else { throw ControlError("Indica el proyecto: este proceso no corre en ningún worktree.") }
        return mine.project
    }

    func createTask(title: String, detail: String? = nil, project name: String? = nil,
                    session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> AgentTask {
        let project = try project(name, session: session)
        let me = caller(session)
        return try workspace.database.createTask(AgentTask(
            projectID: project.id, title: title, detail: detail?.isEmpty == true ? nil : detail,
            createdBy: me?.worktree.id, createdByLabel: me?.worktree.branch ?? "Tú"
        ))
    }

    func tasks(project name: String? = nil, status: AgentTask.Status? = nil,
               session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> [AgentTask] {
        try workspace.database.tasks(project: try project(name, session: session).id, status: status)
    }

    /// Takes an open task for the caller; refuses one someone else is on.
    func claimTask(_ number: Int, project name: String? = nil,
                   session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> AgentTask {
        guard let me = caller(session) else { throw ControlError("Solo el agente de un worktree puede coger una tarea.") }
        let project = try project(name, session: session)
        return try workspace.database.updateTask(project: project.id, number: number) { task in
            switch task.status {
            case .done: throw ControlError("La tarea #\(number) ya está hecha.")
            case .claimed where task.assignee != me.worktree.id:
                throw ControlError("La tarea #\(number) ya la tiene «\(task.assigneeLabel ?? "?")».")
            default:
                task.status = .claimed
                task.assignee = me.worktree.id
                task.assigneeLabel = me.worktree.branch
            }
        }
    }

    /// Marks a task done with its result, which reaches whoever created it by the mailbox.
    func completeTask(_ number: Int, result: String, project name: String? = nil,
                      session: String? = ProcessInfo.processInfo.environment["BULLPEN_SESSION_ID"]) throws -> AgentTask {
        let me = caller(session)
        let project = try project(name, session: session)
        let task = try workspace.database.updateTask(project: project.id, number: number) { task in
            if task.status == .claimed, let assignee = task.assignee, assignee != me?.worktree.id {
                throw ControlError("La tarea #\(number) la tiene «\(task.assigneeLabel ?? "?")»: solo ella puede cerrarla.")
            }
            task.status = .done
            task.result = result
            if task.assignee == nil, let me {
                task.assignee = me.worktree.id
                task.assigneeLabel = me.worktree.branch
            }
        }
        let note = "Tarea #\(task.number) «\(task.title)» hecha por «\(task.assigneeLabel ?? "Tú")»: \(result)"
        if task.createdBy != me?.worktree.id {
            try workspace.database.save(AgentMessage(projectID: project.id, toWorktree: task.createdBy, fromWorktree: me?.worktree.id,
                                                     fromLabel: me?.worktree.branch ?? "Tú", text: note))
        }
        return task
    }
}
