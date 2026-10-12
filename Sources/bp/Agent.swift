import ArgumentParser
import BPAgents
import Foundation

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coding agents (Claude Code, Codex).",
        subcommands: [Command.self, Trust.self]
    )

    struct Trust: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a folder as trusted in Claude Code (skips its trust dialog)."
        )
        @Argument var path: String = FileManager.default.currentDirectoryPath
        @Flag(help: "Remove the folder's entry instead.") var forget = false

        func run() throws {
            let trust = ClaudeTrust()
            let outcome = forget ? try trust.forget(path) : try trust.trust(path)
            print("\(outcome)")
        }
    }

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
            let launch = profile.launch(model: model, prompt: prompt, hooks: hooks)
            print(launch.command)
            if launch.typedPrompt != nil {
                FileHandle.standardError.write(Data("(\(profile.name) no acepta prompt inicial: escríbelo cuando arranque)\n".utf8))
            }
        }
    }
}
