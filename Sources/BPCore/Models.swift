import Foundation

/// A git repository registered in Bullpen. Each project is drawn as one office.
public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var defaultBaseRef: String?
    /// Prompt sent to the agent every time a worktree is created in this project (PLAN §6.5).
    public var initialPrompt: String?
    /// Position of the office in the building (0 = top floor).
    public var sortIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        defaultBaseRef: String? = nil,
        initialPrompt: String? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultBaseRef = defaultBaseRef
        self.initialPrompt = initialPrompt
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// A git worktree inside a project. Each worktree is drawn as one person in the office.
public struct Worktree: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var branch: String
    public var path: String
    public var baseRef: String
    public var createdAt: Date
    public var archivedAt: Date?
    /// Agent launched in this worktree (`claude`, `codex`), nil for a plain terminal.
    public var agentProfileID: String?
    public var agentModel: String?
    /// What the user asked for when creating it.
    public var taskDescription: String?
    /// Ports reserved for `{{port:name}}` in `.bullpen.toml` (PLAN §6.2).
    public var ports: [String: Int]?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        branch: String,
        path: String,
        baseRef: String,
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        agentProfileID: String? = nil,
        agentModel: String? = nil,
        taskDescription: String? = nil,
        ports: [String: Int]? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.branch = branch
        self.path = path
        self.baseRef = baseRef
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.agentProfileID = agentProfileID
        self.agentModel = agentModel
        self.taskDescription = taskDescription
        self.ports = ports
    }

    public var isActive: Bool { archivedAt == nil }
}
