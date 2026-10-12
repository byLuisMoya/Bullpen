import ArgumentParser
import BPCore
import BPSessions
import Foundation

@main
struct BP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bp",
        abstract: "Bullpen command line: manage projects, worktrees and agents.",
        version: Bullpen.version,
        subcommands: [Sessions.self, Agent.self, Hook.self]
    )
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sessions kept alive by the bpd daemon.",
        subcommands: [List.self, Start.self, Send.self, Kill.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct Common: ParsableArguments {
        @Option(help: "bpd socket path.")
        var socket = SessionProtocol.defaultSocketPath

        func connect() throws -> SessionClient {
            do {
                return try SessionClient.connect(socketPath: socket)
            } catch {
                throw ValidationError("bpd is not running (\(socket)).")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List sessions.")
        @OptionGroup var common: Common
        @Flag(help: "Output JSON.") var json = false

        func run() async throws {
            let client = try common.connect()
            defer { client.close() }
            let hello = try await client.hello()
            let sessions = try await client.list()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(sessions), as: UTF8.self))
                return
            }
            print("bpd \(hello.build) (pid \(hello.pid), protocol \(hello.protocolVersion)) — \(sessions.count) session(s)")
            for s in sessions {
                let state = s.exitStatus.map { "exited \($0)" } ?? "running pid \(s.pid)"
                print("\(s.id)  \(state)  \(s.cols)x\(s.rows)  \(s.cwd)  \(s.command ?? "(shell)")")
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a session (login shell, or a command through it).")
        @OptionGroup var common: Common
        @Argument var id: String
        @Option(help: "Working directory.") var cwd = FileManager.default.currentDirectoryPath
        @Option(help: "Command to run; omit for an interactive shell.") var command: String?

        func run() async throws {
            let client = try common.connect()
            defer { client.close() }
            let info = try await client.create(SessionSpec(id: id, cwd: cwd, command: command))
            print("\(info.id) running pid \(info.pid)")
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a message to the program in a session (e.g. an agent).")
        @OptionGroup var common: Common
        @Argument var id: String
        @Argument(help: "Text to send; newlines are kept as one message.") var text: String

        func run() async throws {
            let client = try common.connect()
            defer { client.close() }
            try await client.sendMessage(id, text)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Forget an exited session.")
        @OptionGroup var common: Common
        @Argument var id: String

        func run() async throws {
            let client = try common.connect()
            defer { client.close() }
            try await client.remove(id)
        }
    }

    struct Kill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hang up a session (SIGHUP by default).")
        @OptionGroup var common: Common
        @Argument var id: String
        @Option(help: "Signal number.") var signal: Int32 = SIGHUP

        func run() async throws {
            let client = try common.connect()
            defer { client.close() }
            try await client.kill(id, signal: signal)
        }
    }
}
