import Foundation

/// Marks Bullpen's worktree folders as trusted in Claude Code's `~/.claude.json`, so its
/// "do you trust this folder?" dialog doesn't block every new worktree. Claude Code does not
/// inherit trust from parent folders, so each worktree gets its own entry, removed again when
/// the worktree is removed.
///
/// Claude Code rewrites this file itself, so updates are minimal (one key), atomic
/// (temp file + rename) and verified by reading the file back.
public struct ClaudeTrust: Sendable {
    public var configURL: URL

    public init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")) {
        self.configURL = configURL
    }

    public enum Outcome: Equatable, Sendable {
        case updated, alreadyDone
        /// Claude Code has never run on this Mac (no config file): nothing to do.
        case noClaudeConfig
    }

    @discardableResult
    public func trust(_ path: String) throws -> Outcome {
        let key = Self.key(path)
        return try update { projects in
            var entry = projects[key] as? [String: Any] ?? [:]
            if entry["hasTrustDialogAccepted"] as? Bool == true { return false }
            entry["hasTrustDialogAccepted"] = true
            projects[key] = entry
            return true
        } verify: { projects in
            (projects[key] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
        }
    }

    /// Forgets the folder entirely (it only existed for a worktree that is gone).
    @discardableResult
    public func forget(_ path: String) throws -> Outcome {
        let key = Self.key(path)
        return try update { projects in
            guard projects[key] != nil else { return false }
            projects[key] = nil
            return true
        } verify: { projects in
            projects[key] == nil
        }
    }

    public func isTrusted(_ path: String) -> Bool {
        guard let root = try? read(), let projects = root["projects"] as? [String: Any] else { return false }
        return (projects[Self.key(path)] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
    }

    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private func update(_ change: (inout [String: Any]) -> Bool, verify: ([String: Any]) -> Bool) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .noClaudeConfig }
        for _ in 0..<3 {
            var root = try read()
            var projects = root["projects"] as? [String: Any] ?? [:]
            guard change(&projects) else { return .alreadyDone }
            root["projects"] = projects
            try writeAtomically(root)
            // Claude may have rewritten the file between our read and rename: check and retry.
            if let after = try? read(), verify(after["projects"] as? [String: Any] ?? [:]) { return .updated }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func writeAtomically(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        let temp = configURL.deletingLastPathComponent()
            .appendingPathComponent(".\(configURL.lastPathComponent).bullpen-\(UUID().uuidString)")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions]) ?? 0o600
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, configURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
