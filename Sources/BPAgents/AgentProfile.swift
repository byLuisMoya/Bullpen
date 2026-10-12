import Foundation

/// How to launch a coding-agent CLI inside a worktree's terminal (PLAN §7.1).
public struct AgentProfile: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Executable looked up in the user's login-shell PATH.
    public var executable: String
    /// Suggested models for the picker; any value can be typed.
    public var models: [String]
    /// Names of the foreground process while the agent runs (to tell it apart from the shell).
    public var processNames: [String]

    public static let claude = AgentProfile(
        id: "claude", name: "Claude Code", executable: "claude",
        models: ["opus", "sonnet", "haiku", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
        processNames: ["claude", "node"]
    )

    public static let codex = AgentProfile(
        id: "codex", name: "Codex", executable: "codex",
        models: [],
        processNames: ["codex", "node"]
    )

    public static let all: [AgentProfile] = [.claude, .codex]

    public static func named(_ id: String?) -> AgentProfile? {
        all.first { $0.id == id }
    }

    /// Shell command that starts the agent with its status hooks and, optionally, a first prompt.
    /// When the agent exits the terminal falls back to an interactive shell in the same folder.
    public func command(model: String?, prompt: String?, hooks: AgentHooks) -> String {
        var parts = [executable]
        switch id {
        case "claude":
            parts += ["--settings", shellQuote(hooks.claudeSettingsPath)]
            if let model, !model.isEmpty { parts += ["--model", shellQuote(model)] }
        case "codex":
            parts += ["-c", shellQuote(hooks.codexNotifyConfig)]
            parts += hooks.codexHookConfigs.flatMap { ["-c", shellQuote($0)] }
            if let model, !model.isEmpty { parts += ["--model", shellQuote(model)] }
        default:
            break
        }
        if let prompt, !prompt.isEmpty { parts.append(shellQuote(prompt)) }
        return parts.joined(separator: " ") + "; exec \"$SHELL\" -l"
    }
}
