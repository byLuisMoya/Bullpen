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
        subcommands: [Sessions.self]
    )
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sessions kept alive by the bpd daemon.",
        subcommands: [List.self, Kill.self],
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
