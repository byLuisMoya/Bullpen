import ArgumentParser
import BPAgents
import BPCore
import BPControl
import BPPersistence
import BPSessions
import BPWorkspace
import Foundation

/// The same services the app uses, wired for the command line.
enum CLIContext {
    static var executableDirectory: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent()
    }

    static func service() throws -> ControlService {
        let hooks = AgentHooks.standard(bpPath: executableDirectory.appendingPathComponent("bp").path)
        try? hooks.writeClaudeSettings()
        let bpd = executableDirectory.appendingPathComponent("bpd").path
        let workspace = Workspace(
            database: try AppDatabase.onDisk(),
            connect: { try await DaemonLauncher.connect(bpdPath: bpd) },
            hooks: hooks
        )
        // Inside the app bundle `bp` already shares the app's preferences; elsewhere read them by domain.
        let appDomain = "com.byluismoya.Bullpen"
        let defaults = Bundle.main.bundleIdentifier == appDomain ? UserDefaults.standard : UserDefaults(suiteName: appDomain)
        return ControlService(workspace: workspace, globalPrompt: defaults?.string(forKey: "globalInitialPrompt"))
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "project", abstract: "Projects (git repositories, one office each).",
                                                    subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Forget a project with no active worktrees (nothing is deleted on disk).")
        @Argument var name: String
        func run() async throws {
            try CLIContext.service().removeProject(name: name)
            print("Quitado \(name)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List projects.")
        func run() async throws {
            for p in try CLIContext.service().projects() { print("\(p.name)\t\(p.defaultBaseRef ?? "-")\t\(p.path)") }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add the git repository at a path.")
        @Argument var path: String = FileManager.default.currentDirectoryPath
        func run() async throws {
            let p = try await CLIContext.service().addProject(path: path)
            print("Añadido \(p.name) (base \(p.defaultBaseRef ?? "main"))")
        }
    }
}

struct WorktreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wt", abstract: "Worktrees: create them with an agent, message them, read them, remove them.",
        subcommands: [List.self, Create.self, Send.self, Wait.self, Ask.self, Current.self, Log.self, Remove.self], defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Active worktrees and their agent state.")
        @Option var project: String?
        @Flag var json = false
        func run() async throws {
            let items = try await CLIContext.service().worktrees(project: project)
            if json { try CLIContext.printJSON(items); return }
            for w in items {
                print([w.project, w.branch, w.agent ?? "terminal", w.state, w.detail ?? ""].joined(separator: "\t"))
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a worktree, optionally with an agent and a task.")
        @Option var project: String
        @Option var branch: String
        @Option var base: String?
        @Option(help: "claude, codex, gemini, opencode…") var agent: String?
        @Option var model: String?
        @Option var task: String?
        @Flag(help: "Don't send the global/repo/project initial prompt.") var noInitialPrompt = false
        func run() async throws {
            let wt = try await CLIContext.service().create(project: project, branch: branch, base: base, agent: agent,
                                                           model: model, task: task, initialPrompt: !noInitialPrompt)
            print("Creado \(wt.branch) en \(wt.path)")
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a message to a worktree's agent.")
        @Argument var worktree: String
        @Argument var text: String
        func run() async throws { try await CLIContext.service().send(worktree, text: text) }
    }

    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Wait until a worktree's agent stops (or reaches --until states).")
        @Argument var worktree: String
        @Option(help: "Comma-separated states (default: done,needsYou,idle,error,dead).") var until: String?
        @Option(help: "Seconds.") var timeout = 600
        @Flag var json = false
        func run() async throws {
            let states = until.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) } ?? ControlService.stopStates
            let result = try await CLIContext.service().wait(worktree, until: states, timeout: TimeInterval(timeout))
            if json { try CLIContext.printJSON(result) } else { print([result.state, result.detail ?? ""].joined(separator: "\t")) }
        }
    }

    struct Ask: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a message to a worktree's agent, wait for it to finish and print its answer.")
        @Argument var worktree: String
        @Argument var text: String
        @Option(help: "Seconds.") var timeout = 1800
        func run() async throws { print(try await CLIContext.service().ask(worktree, text: text, timeout: TimeInterval(timeout))) }
    }

    struct Current: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The worktree this terminal belongs to.")
        @Flag var json = false
        func run() async throws {
            let wt = try CLIContext.service().current()
            if json { try CLIContext.printJSON(wt) } else { print([wt.project, wt.branch, wt.path].joined(separator: "\t")) }
        }
    }

    struct Log: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Last lines of a worktree's terminal.")
        @Argument var worktree: String
        @Option var lines = 60
        func run() async throws { print(try CLIContext.service().readTerminal(worktree, lines: lines)) }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a worktree (the branch is kept).")
        @Argument var worktree: String
        @Flag(help: "Remove even if uncommitted or unpushed work would be lost.") var force = false
        func run() async throws {
            try await CLIContext.service().remove(worktree, force: force)
            print("Eliminado \(worktree)")
        }
    }
}

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run Bullpen as an MCP server on stdio (e.g. claude mcp add bullpen -- bp mcp)."
    )
    func run() async throws {
        await MCPServer(service: try CLIContext.service(), version: Bullpen.version).run()
    }
}
