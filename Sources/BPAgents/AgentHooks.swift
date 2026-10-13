import Foundation

/// Wires agent lifecycle hooks to `bp hook <agent>`, which forwards them to `bpd` (PLAN §8.2).
/// Nothing is written into the user's own agent configuration: Claude gets an extra `--settings`
/// file and Codex gets `-c` overrides on its command line.
public struct AgentHooks: Sendable {
    /// Absolute path of the `bp` executable.
    public var bpPath: String
    /// Where the generated Claude settings file lives.
    public var claudeSettingsPath: String
    /// Give launched agents Bullpen's MCP server (`bp mcp`), so they can coordinate with the
    /// other worktrees' agents: create them, ask them, wait for them.
    public var offersBullpenMCP: Bool

    public init(bpPath: String, claudeSettingsPath: String, offersBullpenMCP: Bool = false) {
        self.bpPath = bpPath
        self.claudeSettingsPath = claudeSettingsPath
        self.offersBullpenMCP = offersBullpenMCP
    }

    /// The setting in Settings › General, shared by the app and `bp` (the app's defaults domain).
    public static let coordinationKey = "agents.coordination"
    public static var coordinationEnabled: Bool {
        // Inside the app its defaults are `.standard`; `bp` reads the app's domain by name.
        let appID = "com.byluismoya.Bullpen"
        let defaults = Bundle.main.bundleIdentifier == appID ? .standard : UserDefaults(suiteName: appID)
        return defaults?.object(forKey: coordinationKey) as? Bool ?? true
    }

    /// `--mcp-config` for Claude Code: adds the server for this session only, next to the user's own.
    public var claudeMCPConfig: String {
        let config = ["mcpServers": ["bullpen": ["command": bpPath, "args": ["mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The same servers as a file, for agents that take a path (next to the Claude settings).
    public var mcpConfigPath: String {
        URL(fileURLWithPath: claudeSettingsPath).deletingLastPathComponent().appendingPathComponent("bullpen-mcp.json").path
    }

    /// Writes what `profile` needs to find Bullpen's MCP server before it starts in `worktree`:
    /// the shared servers file, or a `.mcp.json` in the worktree kept out of git.
    public func prepare(_ profile: AgentProfile, in worktree: String) {
        guard offersBullpenMCP, Self.coordinationEnabled, let mcp = profile.mcp else { return }
        let json = Data(claudeMCPConfig.utf8)
        switch mcp {
        case .inlineJSON:
            break
        case .file:
            let url = URL(fileURLWithPath: mcpConfigPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, options: .atomic)
        case .projectFile:
            let dir = URL(fileURLWithPath: worktree)
            let file = dir.appendingPathComponent(".mcp.json")
            // Never overwrite the project's own servers.
            guard !FileManager.default.fileExists(atPath: file.path) else { return }
            try? json.write(to: file, options: .atomic)
            Self.excludeFromGit(".mcp.json", worktree: dir)
        }
    }

    /// Adds `pattern` to the repository's `info/exclude` (shared by its worktrees), once.
    static func excludeFromGit(_ pattern: String, worktree: URL) {
        // In a worktree `.git` is a file: "gitdir: <repo>/.git/worktrees/<name>".
        let dotGit = worktree.appendingPathComponent(".git")
        var gitDir = dotGit
        if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
            gitDir = URL(fileURLWithPath: text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines))
            // `<repo>/.git/worktrees/<name>` → `<repo>/.git`
            if gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
                gitDir = gitDir.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        let exclude = gitDir.appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(Substring(pattern)) else { return }
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// `-c` overrides for Codex.
    public var codexMCPConfigs: [String] {
        ["mcp_servers.bullpen.command=\(tomlString(bpPath))", "mcp_servers.bullpen.args=[\"mcp\"]"]
    }

    static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt",
    ]

    /// Claude Code settings with one async hook per lifecycle event (async: never slows Claude down).
    public func claudeSettings() -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": "\(shellQuote(bpPath)) hook claude",
            "async": true,
            "timeout": 5,
        ]
        var hooks: [String: Any] = [:]
        for event in Self.claudeEvents {
            hooks[event] = [["matcher": "", "hooks": [handler]]]
        }
        return ["hooks": hooks]
    }

    public func writeClaudeSettings() throws {
        let url = URL(fileURLWithPath: claudeSettingsPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: claudeSettings(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// `notify` receives the event JSON as its last argument (`agent-turn-complete`).
    public var codexNotifyConfig: String {
        "notify=[\(tomlString(bpPath)), \"hook\", \"codex\"]"
    }

    /// Inline-TOML lifecycle hooks; Codex passes the event JSON on stdin like Claude does.
    public var codexHookConfigs: [String] {
        Self.codexEvents.map { event in
            "hooks.\(event)=[{hooks=[{type=\"command\", command=\(tomlString("\(shellQuote(bpPath)) hook codex")), timeout=5}]}]"
        }
    }

    private func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public extension AgentHooks {
    /// Hooks pointing at `bpPath`, with the Claude settings file in Application Support.
    static func standard(bpPath: String) -> AgentHooks {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bullpen/agents", isDirectory: true)
        return AgentHooks(bpPath: bpPath, claudeSettingsPath: dir.appendingPathComponent("claude-settings.json").path,
                          offersBullpenMCP: true)
    }
}
