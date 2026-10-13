import BPEnv
import Foundation

/// How a CLI takes its first prompt.
public enum PromptDelivery: Equatable, Sendable {
    /// `agent "prompt"`
    case positional
    /// `agent --prompt "prompt"`
    case flag(String)
    /// The CLI has no such option: Bullpen types it into the terminal once the agent is ready.
    case type
}

/// Which lifecycle hooks Bullpen can wire up for precise status (PLAN §8.2). Others fall back to
/// process and output heuristics.
public enum HookSupport: Equatable, Sendable { case claude, codex, none }

/// How to launch a coding-agent CLI inside a worktree's terminal (PLAN §7.1).
public struct AgentProfile: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Executable (looked up in the login shell's PATH) plus fixed arguments, already shell-safe.
    public var executable: String
    public var arguments: [String]
    public var models: [String]
    public var processNames: [String]
    public var prompt: PromptDelivery
    public var modelFlag: String?
    public var hooks: HookSupport
    /// Defined by the user in a `.toml` file.
    public var isCustom: Bool

    public init(id: String, name: String, executable: String, arguments: [String] = [], models: [String] = [],
                processNames: [String] = [], prompt: PromptDelivery = .positional, modelFlag: String? = "--model",
                hooks: HookSupport = .none, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.models = models
        self.processNames = processNames
        self.prompt = prompt
        self.modelFlag = modelFlag
        self.hooks = hooks
        self.isCustom = isCustom
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let claude = AgentProfile(
        id: "claude", name: "Claude Code", executable: "claude",
        models: ["opus", "sonnet", "haiku", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
        processNames: ["claude"], hooks: .claude
    )
    public static let codex = AgentProfile(id: "codex", name: "Codex", executable: "codex", processNames: ["codex"], hooks: .codex)
    public static let gemini = AgentProfile(id: "gemini", name: "Gemini CLI", executable: "gemini", processNames: ["gemini"],
                                            prompt: .flag("-i"), modelFlag: "-m")
    public static let opencode = AgentProfile(id: "opencode", name: "OpenCode", executable: "opencode", processNames: ["opencode"],
                                              prompt: .flag("--prompt"), modelFlag: "-m")
    public static let cursor = AgentProfile(id: "cursor", name: "Cursor CLI", executable: "cursor-agent", processNames: ["cursor-agent"])
    public static let copilot = AgentProfile(id: "copilot", name: "GitHub Copilot CLI", executable: "copilot", processNames: ["copilot"],
                                             prompt: .type)
    public static let aider = AgentProfile(id: "aider", name: "Aider", executable: "aider", processNames: ["aider"], prompt: .type)
    public static let goose = AgentProfile(id: "goose", name: "Goose", executable: "goose", arguments: ["session"],
                                           processNames: ["goose"], prompt: .type, modelFlag: nil)
    public static let amp = AgentProfile(id: "amp", name: "Amp", executable: "amp", processNames: ["amp"], prompt: .type, modelFlag: nil)

    public static let builtIn: [AgentProfile] = [.claude, .codex, .gemini, .opencode, .cursor, .copilot, .aider, .goose, .amp]

    /// Where custom agent definitions live (one `.toml` per agent).
    public static var customDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bullpen/agents/custom", isDirectory: true)
    }

    /// Built-in agents plus the user's own; a custom file with a built-in id replaces it.
    public static var all: [AgentProfile] {
        let custom = loadCustom(from: customDirectory)
        let ids = Set(custom.map(\.id))
        return builtIn.filter { !ids.contains($0.id) } + custom
    }

    public static func named(_ id: String?) -> AgentProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Parses `id`, `name`, `command`, `prompt` ("positional" | "flag:--x" | "type") and `model_flag`.
    public static func custom(toml: String) throws -> AgentProfile {
        let root = try TOML.parse(toml)
        guard let id = root["id"]?.string, let command = root["command"]?.string else {
            throw TOMLError(line: 1, message: "faltan id o command")
        }
        let words = command.split(separator: " ").map(String.init)
        let prompt: PromptDelivery = switch root["prompt"]?.string ?? "positional" {
        case "type": .type
        case let p where p.hasPrefix("flag:"): .flag(String(p.dropFirst(5)))
        default: .positional
        }
        return AgentProfile(
            id: id, name: root["name"]?.string ?? id, executable: words.first ?? command,
            arguments: Array(words.dropFirst()), processNames: [(words.first as NSString?)?.lastPathComponent ?? id],
            prompt: prompt, modelFlag: root["model_flag"]?.string, isCustom: true
        )
    }

    static func loadCustom(from dir: URL) -> [AgentProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "toml" }.sorted { $0.path < $1.path }
            .compactMap { try? custom(toml: String(contentsOf: $0, encoding: .utf8)) }
    }

    public struct Launch: Equatable, Sendable {
        /// Shell command for the worktree's terminal; falls back to a login shell when the agent exits.
        public var command: String
        /// Prompt to type into the agent once it is ready (agents without a prompt option).
        public var typedPrompt: String?
    }

    public func launch(model: String?, prompt: String?, hooks: AgentHooks) -> Launch {
        var parts = [executable] + arguments
        switch self.hooks {
        case .claude:
            // Read at launch so the setting applies to the next agent without restarting Bullpen.
            // `--mcp-config` takes several values: `--settings` after it ends the list, so a
            // prompt at the end isn't read as one more config.
            if hooks.offersBullpenMCP, AgentHooks.coordinationEnabled { parts += ["--mcp-config", shellQuote(hooks.claudeMCPConfig)] }
            parts += ["--settings", shellQuote(hooks.claudeSettingsPath)]
        case .codex:
            parts += ["-c", shellQuote(hooks.codexNotifyConfig)]
            parts += hooks.codexHookConfigs.flatMap { ["-c", shellQuote($0)] }
            if hooks.offersBullpenMCP, AgentHooks.coordinationEnabled { parts += hooks.codexMCPConfigs.flatMap { ["-c", shellQuote($0)] } }
        case .none:
            break
        }
        if let model, !model.isEmpty, let modelFlag { parts += [modelFlag, shellQuote(model)] }
        var typed: String?
        if let prompt, !prompt.isEmpty {
            switch self.prompt {
            case .positional: parts.append(shellQuote(prompt))
            case let .flag(flag): parts += [flag, shellQuote(prompt)]
            case .type: typed = prompt
            }
        }
        return Launch(command: parts.joined(separator: " ") + "; exec \"$SHELL\" -l", typedPrompt: typed)
    }

    /// Kept for callers that only need the command line.
    public func command(model: String?, prompt: String?, hooks: AgentHooks) -> String {
        launch(model: model, prompt: prompt, hooks: hooks).command
    }
}
