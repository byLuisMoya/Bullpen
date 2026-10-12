@testable import BPAgents
import BPCore
import BPSessions
import BPEnv
import Foundation
import Testing

@Suite struct PromptComposerTests {
    let vars = PromptComposer.variables(projectName: "web-app", branch: "luis/fix", baseRef: "pre", path: "/wt", task: "Arregla el login")

    @Test func composesInOrderAndFillsVariables() throws {
        let prompt = try PromptComposer.compose(
            global: "Responde en español.",
            project: "Proyecto {{project.name}}, rama {{ worktree.branch }} (base {{worktree.baseRef}}).",
            task: "{{task.description}}",
            variables: vars
        )
        #expect(prompt == "Responde en español.\n\nProyecto web-app, rama luis/fix (base pre).\n\nArregla el login")
    }

    @Test func skipsEmptyPartsAndReturnsNilWhenNothing() throws {
        #expect(try PromptComposer.compose(global: "  ", project: nil, task: "", variables: vars) == nil)
        #expect(try PromptComposer.compose(global: nil, project: "solo esto", task: nil, variables: vars) == "solo esto")
    }

    @Test func unknownVariablesAreAnError() {
        #expect(throws: PromptError(unknownVariables: ["ticket.id", "nope"])) {
            try PromptComposer.render("{{ticket.id}} y {{nope}} y {{project.name}}", variables: vars)
        }
    }
}

@Suite struct AgentProfileTests {
    let hooks = AgentHooks(bpPath: "/Apps/Bullpen.app/Contents/MacOS/bp", claudeSettingsPath: "/tmp/claude hooks.json")

    @Test func quotesAnything() {
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("a\nb $HOME") == "'a\nb $HOME'")
    }

    @Test func claudeCommandHasHooksModelPromptAndShellFallback() {
        let cmd = AgentProfile.claude.command(model: "opus", prompt: "Lee CLAUDE.md, ¿vale?", hooks: hooks)
        #expect(cmd == #"claude --settings '/tmp/claude hooks.json' --model 'opus' 'Lee CLAUDE.md, ¿vale?'; exec "$SHELL" -l"#)
    }

    @Test func codexCommandUsesConfigOverrides() {
        let cmd = AgentProfile.codex.command(model: nil, prompt: nil, hooks: hooks)
        #expect(cmd.hasPrefix(#"codex -c 'notify=["/Apps/Bullpen.app/Contents/MacOS/bp", "hook", "codex"]'"#))
        #expect(cmd.contains("hooks.Stop=[{hooks=[{type=\"command\""))
        #expect(cmd.hasSuffix(#"; exec "$SHELL" -l"#))
    }

    @Test func claudeSettingsRegisterAsyncHooks() throws {
        let settings = hooks.claudeSettings()
        let all = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(all.keys) == Set(AgentHooks.claudeEvents))
        let group = try #require((all["PreToolUse"] as? [[String: Any]])?.first)
        let handler = try #require((group["hooks"] as? [[String: Any]])?.first)
        #expect(handler["async"] as? Bool == true)
        #expect(handler["command"] as? String == "'/Apps/Bullpen.app/Contents/MacOS/bp' hook claude")
    }
}

@Suite struct StatusEngineTests {
    let now = Date()

    func session(age: TimeInterval = 60, output: TimeInterval? = nil, fg: String? = "claude",
                 activity: (String, String?, TimeInterval)? = nil, exit: Int32? = nil) -> SessionInfo {
        SessionInfo(
            id: "s", cwd: "/", command: "claude", pid: 1, cols: 80, rows: 24,
            startedAt: now.addingTimeInterval(-age), exitStatus: exit,
            lastOutputAt: output.map { now.addingTimeInterval(-$0) },
            agentActivity: activity.map { AgentActivity(agent: "claude", event: $0.0, detail: $0.1, at: now.addingTimeInterval(-$0.2)) },
            foregroundProcess: fg
        )
    }

    func state(_ s: SessionInfo?, _ profile: AgentProfile? = .claude) -> AgentState {
        StatusEngine.status(for: s, profile: profile, now: now).state
    }

    @Test func hookEventsMapToStates() {
        #expect(state(session(activity: ("UserPromptSubmit", nil, 1))) == .thinking)
        #expect(state(session(activity: ("PreToolUse", "Bash", 1))) == .working)
        #expect(state(session(activity: ("PermissionRequest", "Bash", 1))) == .needsYou)
        #expect(state(session(activity: ("Notification", "permission_prompt", 1))) == .needsYou)
        #expect(state(session(activity: ("Notification", "idle_prompt", 1))) == .done)
        #expect(state(session(activity: ("Stop", nil, 1))) == .done)
        #expect(state(session(activity: ("agent-turn-complete", nil, 1))) == .done)
        #expect(state(session(activity: ("StopFailure", "rate_limit", 1))) == .error)
    }

    @Test func deadProcessesNeverLookAlive() {
        #expect(state(session(activity: ("PreToolUse", "Bash", 1), exit: 0)) == .dead)
        // Agent quit back to the shell, even though its last hook said it was working.
        #expect(state(session(fg: "zsh", activity: ("PreToolUse", "Bash", 1))) == .dead)
        // ...but right after launch the shell is briefly in front before the agent starts.
        #expect(state(session(age: 2, fg: "zsh")) == .starting)
    }

    @Test func staleWorkIsUnknown() {
        #expect(state(session(output: 700, activity: ("PreToolUse", "Bash", 900))) == .unknown)
        #expect(state(session(output: 5, activity: ("PreToolUse", "Bash", 900))) == .working)
    }

    @Test func withoutHooksFallsBackToOutput() {
        #expect(state(session(output: 1)) == .working)
        #expect(state(session(output: 100)) == .unknown)
        #expect(state(nil) == .unknown)
    }

    @Test func plainTerminal() {
        #expect(state(session(output: 1, fg: "zsh"), nil) == .working)
        #expect(state(session(output: 30, fg: "zsh"), nil) == .idle)
    }
}

@Suite struct MoreAgentsTests {
    let hooks = AgentHooks(bpPath: "/bp", claudeSettingsPath: "/s.json")

    @Test func promptDeliveryPerAgent() {
        #expect(AgentProfile.gemini.launch(model: "pro", prompt: "hola", hooks: hooks).command
                == #"gemini -m 'pro' -i 'hola'; exec "$SHELL" -l"#)
        #expect(AgentProfile.opencode.launch(model: nil, prompt: "hola", hooks: hooks).command
                == #"opencode --prompt 'hola'; exec "$SHELL" -l"#)
        let goose = AgentProfile.goose.launch(model: "x", prompt: "hola", hooks: hooks)
        #expect(goose.command == #"goose session; exec "$SHELL" -l"#, "no model flag, prompt typed later")
        #expect(goose.typedPrompt == "hola")
        #expect(AgentProfile.claude.launch(model: nil, prompt: "p", hooks: hooks).typedPrompt == nil)
    }

    @Test func customAgentsFromTOML() throws {
        let profile = try AgentProfile.custom(toml: """
        id = "mine"
        name = "Mi agente"
        command = "/opt/bin/mine --fast"
        prompt = "flag:--task"
        model_flag = "-M"
        """)
        #expect(profile.isCustom && profile.name == "Mi agente")
        #expect(profile.launch(model: "big", prompt: "hazlo", hooks: hooks).command
                == #"/opt/bin/mine --fast -M 'big' --task 'hazlo'; exec "$SHELL" -l"#)
        #expect(profile.processNames == ["mine"])
        #expect(throws: TOMLError.self) { try AgentProfile.custom(toml: "name = 'sin id'") }
    }

    @Test func customDirectoryOverridesBuiltIns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "id = 'aider'\ncommand = 'aider --no-git'\nprompt = 'type'".write(to: dir.appendingPathComponent("a.toml"), atomically: true, encoding: .utf8)
        try "not toml {".write(to: dir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
        let loaded = AgentProfile.loadCustom(from: dir)
        #expect(loaded.map(\.id) == ["aider"])
        #expect(loaded.first?.arguments == ["--no-git"])
    }
}
