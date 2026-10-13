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
        // OpenCode's plugin lives next to it and points at the same `bp`.
        try Data(opencodePlugin.utf8).write(to: URL(fileURLWithPath: opencodePluginPath), options: .atomic)
    }

    // MARK: OpenCode

    /// The plugin OpenCode loads in Bullpen's terminals (next to the Claude settings).
    public var opencodePluginPath: String {
        URL(fileURLWithPath: claudeSettingsPath).deletingLastPathComponent().appendingPathComponent("opencode-bullpen.js").path
    }

    /// `OPENCODE_CONFIG_CONTENT`: OpenCode merges it with the user's config for this run only.
    public func opencodeConfigContent(mcp: Bool) -> String {
        var config: [String: Any] = ["plugin": [URL(fileURLWithPath: opencodePluginPath).absoluteString]]
        if mcp { config["mcp"] = ["bullpen": ["type": "local", "command": [bpPath, "mcp"], "enabled": true]] }
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Turns OpenCode's events into the hook events Bullpen already understands (Claude's names)
    /// and hands them to `bp hook opencode`, without waiting: it can never slow OpenCode down.
    public var opencodePlugin: String {
        let bp = String(decoding: (try? JSONSerialization.data(withJSONObject: [bpPath], options: .withoutEscapingSlashes)) ?? Data("[]".utf8), as: UTF8.self)
        return """
        // Written by Bullpen (rewritten on every start). Tells Bullpen what OpenCode is doing in
        // its worktree terminal; does nothing outside Bullpen.
        import { spawn } from "node:child_process";

        const BP = \(bp)[0];

        export const Bullpen = async () => {
          if (!process.env.BULLPEN_SESSION_ID) return {};
          const children = new Set();   // subagent sessions: their idle isn't the end of the turn
          const roles = new Map();      // messageID → role
          let lastText = "";
          let inTurn = false;           // a prompt is being worked on: its idle is the end of the turn
          let queue = Promise.resolve();
          const clip = (s, n) => (typeof s === "string" ? (s.length > n ? s.slice(0, n) + "…" : s) : undefined);
          // One at a time, in order, never awaited by OpenCode.
          const send = (payload) => {
            queue = queue.then(() => new Promise((done) => {
              try {
                const child = spawn(BP, ["hook", "opencode", JSON.stringify(payload)], { stdio: "ignore" });
                child.on("exit", done);
                child.on("error", done);
                setTimeout(done, 2000);
              } catch { done(); }
            }));
          };
          send({ hook_event_name: "SessionStart" });
          return {
            "chat.message": async (input, output) => {
              const text = (output?.parts ?? []).filter((p) => p?.type === "text").map((p) => p.text).join("\\n");
              inTurn = true;
              lastText = "";
              send({ hook_event_name: "UserPromptSubmit", prompt: clip(text, 2000) });
            },
            "tool.execute.before": async (input, output) => {
              send({ hook_event_name: "PreToolUse", tool_name: input?.tool, tool_input: output?.args ?? {} });
            },
            "tool.execute.after": async (input) => {
              send({ hook_event_name: "PostToolUse", tool_name: input?.tool });
            },
            event: async ({ event }) => {
              const p = event?.properties ?? {};
              switch (event?.type) {
                case "session.created":
                  if (p.info?.parentID) children.add(p.info.id);
                  break;
                case "message.updated":
                  if (p.info?.id) roles.set(p.info.id, p.info.role);
                  break;
                case "message.part.updated":
                  if (p.part?.type === "text" && roles.get(p.part.messageID) === "assistant" && !children.has(p.part.sessionID)) lastText = p.part.text ?? lastText;
                  break;
                case "permission.asked":
                  send({ hook_event_name: "PermissionRequest", tool_name: p.permission ?? p.type,
                         tool_input: { command: (p.patterns ?? []).join(" ") || undefined } });
                  break;
                case "question.asked":
                  send({ hook_event_name: "Notification", notification_type: "question",
                         message: clip(p.questions?.[0]?.question, 400) });
                  break;
                case "permission.replied":
                case "question.replied":
                  send({ hook_event_name: "PostToolUse" });
                  break;
                case "session.idle":
                  if (children.has(p.sessionID) || !inTurn) break;
                  inTurn = false;
                  send({ hook_event_name: "Stop", last_assistant_message: clip(lastText, 1500) });
                  break;
                case "session.error":
                  if (children.has(p.sessionID)) break;
                  inTurn = false;
                  if (p.error?.name === "MessageAbortedError") send({ hook_event_name: "Interrupt" });
                  else send({ hook_event_name: "StopFailure", error_type: clip(p.error?.data?.message ?? p.error?.name, 200) });
                  break;
              }
            },
          };
        };

        """
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
