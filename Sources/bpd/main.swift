import BPCore
import BPSessions
import Foundation

// bpd: Bullpen's session daemon. Started by the app (detached, own session) and kept alive
// while it has running sessions or clients, so agents survive closing or updating the app.
let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

signal(SIGPIPE, SIG_IGN)

// Used from the signal handler below, which runs off the main thread once dispatchMain() parks it.
let server = SessionServer(
    socketPath: value("--socket") ?? SessionProtocol.defaultSocketPath,
    logDirectory: value("--logs").map { URL(fileURLWithPath: $0) } ?? SessionProtocol.defaultLogDirectory,
    build: Bullpen.version
)
server.onExit = { exit(0) }
do {
    // Started to replace an older bpd: take its terminals over first (they keep running).
    if args.contains("--takeover") { try server.adopt(from: server.socketPath) }
    try server.start()
} catch {
    FileHandle.standardError.write(Data("bpd: cannot start: \(error)\n".utf8))
    exit(1)
}

let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
signal(SIGTERM, SIG_IGN)
term.setEventHandler { @Sendable in
    server.stop()
    exit(0)
}
term.resume()
dispatchMain()
