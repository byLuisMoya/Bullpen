import BPCore
import Foundation
import GRDB

/// SQLite storage for Bullpen (PLAN §4.2, `BPPersistence`).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Database file in `~/Library/Application Support/Bullpen/bullpen.sqlite`.
    public static func onDisk() throws -> AppDatabase {
        let url = try Bullpen.supportDirectory().appendingPathComponent("bullpen.sqlite")
        return try AppDatabase(DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        // Never erase on schema changes: the app and `bp` share this database.
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("defaultBaseRef", .text)
                t.column("initialPrompt", .text)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "worktree") { t in
                t.primaryKey("id", .blob)
                t.column("projectID", .blob).notNull().indexed()
                    .references("project", onDelete: .cascade)
                t.column("branch", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("baseRef", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
            }
        }
        migrator.registerMigration("v2-agents") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "agentProfileID", .text)
                t.add(column: "agentModel", .text)
                t.add(column: "taskDescription", .text)
            }
        }
        migrator.registerMigration("v3-ports") { db in
            try db.alter(table: "worktree") { t in t.add(column: "ports", .text) }
        }
        migrator.registerMigration("v4-runs") { db in
            try db.create(table: "run") { t in
                t.primaryKey("id", .blob)
                t.column("projectID", .blob).notNull().indexed().references("project", onDelete: .cascade)
                t.column("task", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("verdict", .text)
            }
            try db.alter(table: "worktree") { t in t.add(column: "runID", .blob) }
        }
        migrator.registerMigration("v5-tickets") { db in
            try db.alter(table: "worktree") { t in t.add(column: "ticket", .text) }
        }
        migrator.registerMigration("v6-setup-script") { db in
            try db.alter(table: "project") { t in t.add(column: "setupScript", .text) }
        }
        migrator.registerMigration("v7-external-worktrees") { db in
            try db.alter(table: "worktree") { t in t.add(column: "external", .boolean).notNull().defaults(to: false) }
        }
        migrator.registerMigration("v8-automations") { db in
            try db.create(table: "automation") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("projectID", .blob).notNull().indexed().references("project", onDelete: .cascade)
                t.column("agentID", .text)
                t.column("task", .text).notNull()
                t.column("weekdays", .text).notNull()
                t.column("hour", .integer).notNull()
                t.column("minute", .integer).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("lastRun", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v9-office-themes") { db in
            try db.alter(table: "project") { t in t.add(column: "officeTheme", .text) }
        }
        migrator.registerMigration("v10-archive-script") { db in
            try db.alter(table: "project") { t in t.add(column: "archiveScript", .text) }
        }
        migrator.registerMigration("v11-reviews") { db in
            try db.alter(table: "project") { t in
                t.add(column: "reviewAuto", .boolean)
                t.add(column: "reviewExhaustiveFrom", .integer)
            }
            try db.alter(table: "worktree") { t in t.add(column: "review", .text) }
        }
        migrator.registerMigration("v12-coordination") { db in
            try db.create(table: "agentMessage") { t in
                t.primaryKey("id", .blob)
                t.column("projectID", .blob).notNull().indexed().references("project", onDelete: .cascade)
                t.column("toWorktree", .blob).indexed()
                t.column("fromWorktree", .blob)
                t.column("fromLabel", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
                t.column("readAt", .datetime)
            }
            try db.create(table: "agentTask") { t in
                t.primaryKey("id", .blob)
                t.column("projectID", .blob).notNull().references("project", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("status", .text).notNull()
                t.column("createdBy", .blob)
                t.column("createdByLabel", .text).notNull()
                t.column("assignee", .blob)
                t.column("assigneeLabel", .text)
                t.column("result", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["projectID", "number"])
            }
        }
        migrator.registerMigration("v13-worktree-path-unique-while-active") { db in
            // A path is one active worktree's; an archived one keeps its record (runs, history)
            // without blocking a new worktree at the same place. SQLite can't drop a column's
            // UNIQUE: the table is rebuilt (nothing references it by key).
            try db.execute(sql: """
                CREATE TABLE "worktree_v13" ("id" BLOB PRIMARY KEY NOT NULL,
                    "projectID" BLOB NOT NULL REFERENCES "project"("id") ON DELETE CASCADE,
                    "branch" TEXT NOT NULL, "path" TEXT NOT NULL, "baseRef" TEXT NOT NULL,
                    "createdAt" DATETIME NOT NULL, "archivedAt" DATETIME, "agentProfileID" TEXT,
                    "agentModel" TEXT, "taskDescription" TEXT, "ports" TEXT, "runID" BLOB, "ticket" TEXT,
                    "external" BOOLEAN NOT NULL DEFAULT 0, "review" TEXT);
                INSERT INTO "worktree_v13" ("id", "projectID", "branch", "path", "baseRef", "createdAt", "archivedAt",
                    "agentProfileID", "agentModel", "taskDescription", "ports", "runID", "ticket", "external", "review")
                    SELECT "id", "projectID", "branch", "path", "baseRef", "createdAt", "archivedAt",
                    "agentProfileID", "agentModel", "taskDescription", "ports", "runID", "ticket", "external", "review"
                    FROM "worktree";
                DROP TABLE "worktree";
                ALTER TABLE "worktree_v13" RENAME TO "worktree";
                CREATE INDEX "worktree_on_projectID" ON "worktree"("projectID");
                CREATE UNIQUE INDEX "worktree_active_path" ON "worktree"("path") WHERE "archivedAt" IS NULL;
                """)
        }
        return migrator
    }
}

// MARK: - Projects

extension AgentMessage: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agentMessage"
}

extension AgentTask: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agentTask"
}

extension Automation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "automation"
}

extension Project: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
}

extension Run: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "run"
}

extension Worktree: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "worktree"
}

public enum DatabaseTaskError: Error, LocalizedError, Equatable {
    case notFound(Int)
    public var errorDescription: String? {
        switch self {
        case let .notFound(number): "No hay ninguna tarea #\(number) en este proyecto."
        }
    }
}

/// A project with its active worktrees: one floor of the building.
public struct Office: Identifiable, Hashable, Sendable {
    public var project: Project
    public var worktrees: [Worktree]
    public var id: UUID { project.id }
    public var lighting: OfficeLighting { OfficeLighting(activeWorktrees: worktrees.count) }
}

public extension AppDatabase {
    func save(_ project: Project) throws {
        try writer.write { try project.save($0) }
    }

    func save(_ worktree: Worktree) throws {
        try writer.write { try worktree.save($0) }
    }

    func save(_ run: Run) throws {
        try writer.write { try run.save($0) }
    }

    func run(id: UUID) throws -> Run? {
        try writer.read { try Run.fetchOne($0, key: id) }
    }

    /// Every worktree of a run, archived ones included (the losers stay listed after a pick).
    func worktrees(inRun id: UUID) throws -> [Worktree] {
        try writer.read { try Worktree.filter(Column("runID") == id).order(Column("createdAt")).fetchAll($0) }
    }

    func automations() throws -> [Automation] {
        try writer.read { try Automation.order(Column("createdAt")).fetchAll($0) }
    }

    func save(_ automation: Automation) throws {
        try writer.write { try automation.save($0) }
    }

    func deleteAutomation(id: UUID) throws {
        _ = try writer.write { try Automation.deleteOne($0, key: id) }
    }

    /// Every worktree ever recorded, archived ones included (their paths are not imported again).
    func allWorktrees() throws -> [Worktree] {
        try writer.read { try Worktree.fetchAll($0) }
    }

    func deleteProject(id: UUID) throws {
        _ = try writer.write { try Project.deleteOne($0, key: id) }
    }

    /// Puts the offices in this order; projects left out keep their place after them.
    func reorderProjects(_ ids: [UUID]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try Project.filter(key: id).updateAll(db, Column("sortIndex").set(to: index))
            }
            let rest = try Project.filter(!ids.contains(Column("id"))).order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
            for (offset, project) in rest.enumerated() {
                try Project.filter(key: project.id).updateAll(db, Column("sortIndex").set(to: ids.count + offset))
            }
        }
    }

    // MARK: Coordination

    func save(_ message: AgentMessage) throws {
        try writer.write { try message.save($0) }
    }

    /// A worktree's mailbox (nil: the user's) in a project, oldest first.
    func messages(to worktree: UUID?, unreadOnly: Bool = false) throws -> [AgentMessage] {
        try writer.read { db in
            var request = AgentMessage.filter(Column("toWorktree") == worktree)
            if unreadOnly { request = request.filter(Column("readAt") == nil) }
            return try request.order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Everything a worktree sent or received, oldest first.
    func conversation(of worktree: UUID) throws -> [AgentMessage] {
        try writer.read { db in
            try AgentMessage.filter(Column("toWorktree") == worktree || Column("fromWorktree") == worktree)
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Messages still waiting to reach their recipient.
    func undeliveredMessages() throws -> [AgentMessage] {
        try writer.read { try AgentMessage.filter(Column("deliveredAt") == nil).order(Column("createdAt")).fetchAll($0) }
    }

    /// Marks messages delivered (and, with `read`, read).
    func markMessages(_ ids: [UUID], read: Bool = false) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            let now = Date()
            for id in ids {
                guard var message = try AgentMessage.fetchOne(db, key: id) else { continue }
                message.deliveredAt = message.deliveredAt ?? now
                if read { message.readAt = message.readAt ?? now }
                try message.save(db)
            }
        }
    }

    /// Adds a task to its project's board with the next number.
    func createTask(_ task: AgentTask) throws -> AgentTask {
        try writer.write { db in
            var task = task
            let last = try Int.fetchOne(db, sql: "SELECT MAX(number) FROM agentTask WHERE projectID = ?", arguments: [task.projectID]) ?? 0
            task.number = last + 1
            try task.insert(db)
            return task
        }
    }

    func tasks(project: UUID, status: AgentTask.Status? = nil) throws -> [AgentTask] {
        try writer.read { db in
            var request = AgentTask.filter(Column("projectID") == project)
            if let status { request = request.filter(Column("status") == status.rawValue) }
            return try request.order(Column("number")).fetchAll(db)
        }
    }

    /// Changes one task in a single transaction: `change` sees the current row and may refuse.
    func updateTask(project: UUID, number: Int, _ change: (inout AgentTask) throws -> Void) throws -> AgentTask {
        try writer.write { db in
            guard var task = try AgentTask.filter(Column("projectID") == project && Column("number") == number).fetchOne(db) else {
                throw DatabaseTaskError.notFound(number)
            }
            try change(&task)
            task.updatedAt = Date()
            try task.save(db)
            return task
        }
    }

    /// Offices in building order, each with its active (non-archived) worktrees.
    func offices() throws -> [Office] {
        try writer.read(Self.fetchOffices)
    }

    /// Emits the building every time projects or worktrees change.
    func observeOffices() -> AsyncValueObservation<[Office]> {
        ValueObservation.tracking(Self.fetchOffices).values(in: writer)
    }

    private static func fetchOffices(_ db: Database) throws -> [Office] {
        let projects = try Project.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
        let worktrees = try Worktree
            .filter(Column("archivedAt") == nil)
            .order(Column("createdAt"))
            .fetchAll(db)
        let byProject = Dictionary(grouping: worktrees, by: \.projectID)
        return projects.map { Office(project: $0, worktrees: byProject[$0.id] ?? []) }
    }
}
