import Foundation

/// A git repository registered in Bullpen. Each project is drawn as one office.
public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var defaultBaseRef: String?
    /// Prompt sent to the agent every time a worktree is created in this project (PLAN §6.5).
    public var initialPrompt: String?
    /// Shell script run in every new worktree of this project, before the agent starts (after
    /// `.bullpen.toml`'s `[setup] run`). Saved from "Nuevo worktree › Avanzado".
    public var setupScript: String?
    /// Shell script run in a worktree of this project when it is removed, before its folder goes
    /// (after `.bullpen.toml`'s `[teardown] run`): stop servers, undo links…
    public var archiveScript: String?
    /// Review a worktree's PR automatically when its agent finishes (nil: yes, the quick one).
    public var reviewAuto: Bool?
    /// The exhaustive review instead of the quick one from this many changed files (nil: 90, 0: never).
    public var reviewExhaustiveFrom: Int?
    /// The office's style (`OfficeTheme` raw value); nil is the basic one.
    public var officeTheme: String?
    /// Position of the office in the building (0 = top floor).
    public var sortIndex: Int
    public var createdAt: Date

    /// The "Reviews" office: not a repository, it holds the reviewers of other worktrees' PRs.
    public static let reviewsID = UUID(uuidString: "0B5E4E3E-0000-4000-8000-00000000BEEF")!
    public var isReviews: Bool { id == Self.reviewsID }
    public var reviewsAutomatically: Bool { reviewAuto ?? true }
    public var exhaustiveReviewFrom: Int { reviewExhaustiveFrom ?? 90 }

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        defaultBaseRef: String? = nil,
        initialPrompt: String? = nil,
        setupScript: String? = nil,
        archiveScript: String? = nil,
        officeTheme: String? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultBaseRef = defaultBaseRef
        self.initialPrompt = initialPrompt
        self.setupScript = setupScript
        self.archiveScript = archiveScript
        self.officeTheme = officeTheme
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
    /// Set when this worktree is one of several agents working on the same task (a fan-out run).
    public var runID: UUID?
    /// The ticket it was created from (GitHub issue, Linear issue).
    public var ticket: TicketRef?
    /// Made outside Bullpen (Orca, plain git) and shown here: removing it only hides it.
    public var external: Bool
    /// Set on the reviewers in the Reviews office: whose PR they review and how it went.
    public var review: ReviewInfo?

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
        ports: [String: Int]? = nil,
        runID: UUID? = nil,
        ticket: TicketRef? = nil,
        external: Bool = false,
        review: ReviewInfo? = nil
    ) {
        self.external = external
        self.review = review
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
        self.runID = runID
        self.ticket = ticket
    }

    public var isActive: Bool { archivedAt == nil }
}

/// A reviewer's job: one worktree's PR at one commit, in a detached checkout of its repository.
public struct ReviewInfo: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case quick, exhaustive }
    public enum Phase: String, Codable, Sendable {
        /// The review command is running.
        case reviewing
        /// Asked for the verdict and its reasons.
        case summarizing
        /// Verdict in; its fixes (uncommitted) wait for the user.
        case done
        /// The user accepted the fixes: committed and pushed to the PR.
        case applied
    }

    /// The worktree whose PR is reviewed.
    public var of: UUID
    public var kind: Kind
    /// Repository the reviewer's checkout belongs to (the reviewed project's).
    public var repoPath: String
    /// The PR's branch, where accepted fixes are pushed.
    public var branch: String
    public var pullRequest: Int?
    /// Commit reviewed (the checkout starts there, so its diff is the reviewer's fixes).
    public var commit: String
    public var phase: Phase
    /// When the verdict was asked for (its answer is the first stop after it).
    public var summaryRequestedAt: Date?
    /// Can it go up? nil until the reviewer says.
    public var approved: Bool?
    public var summary: String?
    /// The commit pushed with the accepted fixes (not reviewed again because of them).
    public var appliedCommit: String?

    public init(of: UUID, kind: Kind, repoPath: String, branch: String, pullRequest: Int?, commit: String,
                phase: Phase = .reviewing) {
        self.of = of
        self.kind = kind
        self.repoPath = repoPath
        self.branch = branch
        self.pullRequest = pullRequest
        self.commit = commit
        self.phase = phase
    }

    /// Reads the verdict line the reviewer was asked to start with.
    public static func verdict(in text: String) -> Bool? {
        let upper = text.uppercased()
        guard let range = upper.range(of: "VEREDICTO:") else { return nil }
        let line = upper[range.upperBound...].prefix { $0 != "\n" }
        if line.contains("NO SE PUEDE") { return false }
        if line.contains("SE PUEDE") { return true }
        return nil
    }
}

/// One task given to several agents at once, each in its own worktree, to compare (PLAN §11.2).
public struct Run: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var task: String
    public var createdAt: Date
    /// The judge model's comparison, if asked for.
    public var verdict: String?

    public init(id: UUID = UUID(), projectID: UUID, task: String, createdAt: Date = Date(), verdict: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.task = task
        self.createdAt = createdAt
        self.verdict = verdict
    }
}

/// Enough of a tracker ticket to link back and update it (PLAN §11.5).
public struct TicketRef: Hashable, Codable, Sendable {
    /// `github` or `linear`.
    public var source: String
    public var trackerID: String
    /// `FKPI-123`, `#45`.
    public var key: String
    public var url: URL?
    public var teamID: String?

    public init(source: String, trackerID: String, key: String, url: URL?, teamID: String? = nil) {
        self.source = source
        self.trackerID = trackerID
        self.key = key
        self.url = url
        self.teamID = teamID
    }
}
