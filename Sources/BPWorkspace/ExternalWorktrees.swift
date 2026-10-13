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
        let output = await Task.detached { () -> Data? in
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
        }.value
        return output.map(parse) ?? []
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

public extension Workspace {
    /// Shows worktrees made outside Bullpen (with Orca, or plain git) in their project's office,
    /// for the projects registered here only. Worktrees that disappear from git leave Bullpen;
    /// one the user removed from Bullpen (an archived record) is not brought back.
    @discardableResult
    func syncExternalWorktrees(orca given: [OrcaWorktree]? = nil) async throws -> (added: Int, gone: Int) {
        let orca: [OrcaWorktree]
        if let given { orca = given } else { orca = await OrcaWorktree.list() }
        let orcaByPath = Dictionary(orca.map { (Self.canonical($0.path), $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(try database.allWorktrees().map { Self.canonical($0.path) })
        var added = 0, gone = 0
        for office in try database.offices() {
            guard let repo = try? await Repository.open(at: URL(fileURLWithPath: office.project.path)) else { continue }
            let onDisk = try await repo.worktrees().filter { !$0.isMain && !$0.isPrunable }
            let paths = Set(onDisk.map { Self.canonical($0.path) })
            for found in onDisk {
                let path = Self.canonical(found.path)
                guard !known.contains(path), orcaByPath[path]?.archived != true else { continue }
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
