import ArgumentParser
import BPAgents
import Foundation

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coding agents (Claude Code, Codex).",
        subcommands: [Command.self]
    )

    struct Command: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the shell command that starts an agent with Bullpen's status hooks."
        )
        @Argument(help: "claude or codex.") var agent: String
        @Option var model: String?
        @Option var prompt: String?

        func run() throws {
            guard let profile = AgentProfile.named(agent) else {
                throw ValidationError("Unknown agent \(agent). Known: \(AgentProfile.all.map(\.id).joined(separator: ", "))")
            }
            let bpPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
            let hooks = AgentHooks.standard(bpPath: bpPath)
            try hooks.writeClaudeSettings()
            print(profile.command(model: model, prompt: prompt, hooks: hooks))
        }
    }
}
