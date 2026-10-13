import Foundation

/// A message left in an agent's mailbox (or the user's): unlike typing into its terminal, it
/// waits until the agent finishes its turn, so it never interrupts work in progress.
public struct AgentMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var projectID: UUID
    /// Recipient worktree; nil is the user.
    public var toWorktree: UUID?
    /// Sender worktree; nil is the user.
    public var fromWorktree: UUID?
    /// Who wrote it, as shown: the sender's branch, or "Tú".
    public var fromLabel: String
    public var text: String
    public var createdAt: Date
    /// Typed into the recipient's terminal (or shown to the user).
    public var deliveredAt: Date?
    /// Read with `read_inbox`.
    public var readAt: Date?

    public init(id: UUID = UUID(), projectID: UUID, toWorktree: UUID?, fromWorktree: UUID?, fromLabel: String,
                text: String, createdAt: Date = Date(), deliveredAt: Date? = nil, readAt: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.toWorktree = toWorktree
        self.fromWorktree = fromWorktree
        self.fromLabel = fromLabel
        self.text = text
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
    }
}

/// A task on a project's shared board: any agent (or the user) adds it, one agent claims it,
/// and its result goes back to whoever asked.
public struct AgentTask: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case open, claimed, done

        public var title: String {
            switch self {
            case .open: "Pendiente"
            case .claimed: "En curso"
            case .done: "Hecha"
            }
        }
    }

    public var id: UUID
    public var projectID: UUID
    /// #1, #2… within the project: what agents call it.
    public var number: Int
    public var title: String
    public var detail: String?
    public var status: Status
    public var createdBy: UUID?
    public var createdByLabel: String
    public var assignee: UUID?
    public var assigneeLabel: String?
    public var result: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), projectID: UUID, number: Int = 0, title: String, detail: String? = nil,
                status: Status = .open, createdBy: UUID?, createdByLabel: String, assignee: UUID? = nil,
                assigneeLabel: String? = nil, result: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.number = number
        self.title = title
        self.detail = detail
        self.status = status
        self.createdBy = createdBy
        self.createdByLabel = createdByLabel
        self.assignee = assignee
        self.assigneeLabel = assigneeLabel
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
