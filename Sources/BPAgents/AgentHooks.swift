import Foundation

/// Wires agent lifecycle hooks to `bp hook <agent>`, which forwards them to `bpd` (PLAN §8.2).
/// Nothing is written into the user's own agent configuration: Claude gets an extra `--settings`
/// file and Codex gets `-c` overrides on its command line.
public struct AgentHooks: Sendable {
    /// Absolute path of the `bp` executable.
    public var bpPath: String
    /// Where the generated Claude settings file lives.
    public var claudeSettingsPath: String

    public init(bpPath: String, claudeSettingsPath: String) {
        self.bpPath = bpPath
        self.claudeSettingsPath = claudeSettingsPath
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
        return AgentHooks(bpPath: bpPath, claudeSettingsPath: dir.appendingPathComponent("claude-settings.json").path)
    }
}
