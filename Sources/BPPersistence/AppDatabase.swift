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
        return migrator
    }
}

// MARK: - Projects

extension Project: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
}

extension Run: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "run"
}

extension Worktree: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "worktree"
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

    func deleteProject(id: UUID) throws {
        _ = try writer.write { try Project.deleteOne($0, key: id) }
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
