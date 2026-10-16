import BPCore
import BPGit
import Foundation

/// What Orca knows about its worktrees, read through its CLI (`orca worktree list --json`):
/// the base each one started from, and whether it is archived there.
public struct OrcaWorktree: Equatable, Sendable {
    public var path: String
    public var baseRef: String?
    public var archived: Bool

    public init(path: String, baseRef: String?, archived: Bool) {
        self.path = path
        self.baseRef = baseRef
        self.archived = archived
    }

    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/orca", "/opt/homebrew/bin/orca", "\(home)/.local/bin/orca", "\(home)/bin/orca"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Orca's worktrees, or none if Orca is not installed or doesn't answer.
    public static func list() async -> [OrcaWorktree] {
        guard let orca = locate() else { return [] }
        let output = await offPool { () -> Data? in
            let process = Process()
            process.executableURL = orca
            process.arguments = ["worktree", "list", "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }
        return output.map(parse) ?? []
    }

    /// Deletes a worktree through Orca (folder, git registration and Orca's own entry), so Orca
    /// isn't left pointing at a missing folder. `force` also drops uncommitted changes.
    public static func remove(path: String, force: Bool) async throws {
        guard let orca = locate() else { throw WorkspaceError(message: "No se encuentra el comando orca.") }
        let (status, output) = await offPool { () -> (Int32, String) in
            let process = Process()
            process.executableURL = orca
            process.arguments = ["worktree", "rm", "--worktree", "path:\(path)", "--json"] + (force ? ["--force"] : [])
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            guard (try? process.run()) != nil else { return (-1, "") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        guard status == 0 else {
            let message = (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
            throw WorkspaceError(message: "Orca no pudo eliminarlo: \(message ?? output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// `{"result": {"worktrees": [...]}}` (or the bare list), with refs like `refs/remotes/origin/main`.
    static func parse(_ data: Data) -> [OrcaWorktree] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let result = (json as? [String: Any])?["result"] ?? json
        let items = (result as? [String: Any])?["worktrees"] as? [[String: Any]] ?? result as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let path = item["path"] as? String else { return nil }
            return OrcaWorktree(path: path, baseRef: (item["baseRef"] as? String).map(shortRef), archived: item["isArchived"] as? Bool ?? false)
        }
    }

    /// `refs/remotes/origin/main` → `origin/main`, `refs/heads/pre` → `pre`.
    static func shortRef(_ ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }
}

/// What Orca shows for one of its worktrees right now (`orca worktree ps --json`): its agent's
/// state, what it was asked and its last answer, and when its terminal last printed.
public struct OrcaActivity: Equatable, Sendable {
    public var path: String
    /// Orca's word for the agent's state ("working", "done", "waiting"…), lowercased.
    public var agentState: String?
    public var agentType: String?
    public var prompt: String?
    public var lastMessage: String?
    public var lastOutputAt: Date?
    public var liveTerminals: Int

    public init(path: String, agentState: String?, agentType: String?, prompt: String?, lastMessage: String?,
                lastOutputAt: Date?, liveTerminals: Int) {
        self.path = path
        self.agentState = agentState
        self.agentType = agentType
        self.prompt = prompt
        self.lastMessage = lastMessage
        self.lastOutputAt = lastOutputAt
        self.liveTerminals = liveTerminals
    }

    /// Bullpen's state for Orca's: unknown words fall back to recent terminal output.
    public func state(now: Date = Date()) -> AgentState {
        switch agentState ?? "" {
        case "working", "running", "busy", "active", "tool", "executing": return .working
        case "thinking", "planning", "generating": return .thinking
        case "waiting", "blocked", "needs-input", "needs_input", "input", "permission", "attention", "awaiting-input", "awaiting_input", "question":
            return .needsYou
        case "done", "complete", "completed", "finished", "success": return .done
        case "error", "failed", "failure", "crashed": return .error
        case "idle", "ready": return .idle
        default:
            if liveTerminals == 0 { return .dead }
            if let lastOutputAt, now.timeIntervalSince(lastOutputAt) < 5 { return .working }
            return .idle
        }
    }

    public static func list() async -> [OrcaActivity] {
        guard let orca = OrcaWorktree.locate() else { return [] }
        let output = await offPool { () -> Data? in
            let process = Process()
            process.executableURL = orca
            process.arguments = ["worktree", "ps", "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }
        return output.map(parse) ?? []
    }

    static func parse(_ data: Data) -> [OrcaActivity] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let rows = ((json["result"] as? [String: Any])?["worktrees"] ?? json["worktrees"]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let path = row["path"] as? String else { return nil }
            // The most recent agent pane speaks for the worktree.
            let agent = (row["agents"] as? [[String: Any]])?.last
            func date(_ key: String) -> Date? {
                (row[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            }
            return OrcaActivity(
                path: path, agentState: (agent?["state"] as? String)?.lowercased(), agentType: agent?["agentType"] as? String,
                prompt: agent?["prompt"] as? String, lastMessage: agent?["lastAssistantMessage"] as? String,
                lastOutputAt: date("lastOutputAt"), liveTerminals: (row["liveTerminalCount"] as? NSNumber)?.intValue ?? 0
            )
        }
    }
}

public extension Workspace {
    private static func byPath(_ orca: [OrcaWorktree]) -> [String: OrcaWorktree] {
        Dictionary(orca.map { (canonical($0.path), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Shows worktrees made outside Bullpen (with Orca, or plain git) in their project's office,
    /// for the projects registered here only. Worktrees that disappear from git leave Bullpen;
    /// one the user hid from Bullpen (an archived external record) is not brought back. An
    /// archived worktree of Bullpen's had its folder deleted: one there now is a new one.
    @discardableResult
    func syncExternalWorktrees(orca given: [OrcaWorktree]? = nil) async throws -> (added: Int, gone: Int) {
        // Orca's list (a CLI run) only matters for worktrees not known yet: read it the first time one appears.
        var orcaByPath: [String: OrcaWorktree]? = given.map { Self.byPath($0) }
        // A reviewer's folder may outlive its record (its removal doesn't stop the archive): not imported.
        let known = Set(try database.allWorktrees().filter { $0.isActive || $0.external || $0.review != nil }.map { Self.canonical($0.path) })
        var added = 0, gone = 0
        for office in try database.offices() {
            guard let repo = try? await Repository.open(at: URL(fileURLWithPath: office.project.path)) else { continue }
            let onDisk = try await repo.worktrees().filter { !$0.isMain && !$0.isPrunable }
            let paths = Set(onDisk.map { Self.canonical($0.path) })
            for found in onDisk {
                let path = Self.canonical(found.path)
                guard !known.contains(path) else { continue }
                if orcaByPath == nil { orcaByPath = Self.byPath(await OrcaWorktree.list()) }
                let orcaByPath = orcaByPath ?? [:]
                guard orcaByPath[path]?.archived != true else { continue }
                let worktree = Worktree(
                    projectID: office.project.id,
                    branch: found.branch ?? URL(fileURLWithPath: found.path).lastPathComponent,
                    path: found.path,
                    baseRef: orcaByPath[path]?.baseRef ?? office.project.defaultBaseRef ?? "main",
                    external: true
                )
                try database.save(worktree)
                added += 1
            }
            for worktree in office.worktrees where worktree.external && !paths.contains(Self.canonical(worktree.path)) {
                var archived = worktree
                archived.archivedAt = Date()
                try database.save(archived)
                gone += 1
            }
        }
        return (added, gone)
    }

    /// Same folder whatever the spelling (`/private/tmp` vs `/tmp`, trailing slash).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
