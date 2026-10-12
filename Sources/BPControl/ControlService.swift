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

    public func send(_ reference: String, text: String) async throws {
        let (wt, _) = try find(reference)
        let client = try await workspace.connect()
        let id = Workspace.sessionID(for: wt)
        guard try await client.list().contains(where: { $0.id == id && $0.isRunning }) else {
            throw ControlError("«\(wt.branch)» no tiene una terminal en marcha.")
        }
        try await client.sendMessage(id, text)
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
