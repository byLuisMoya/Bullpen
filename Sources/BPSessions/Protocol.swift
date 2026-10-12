import Foundation

/// Wire protocol between the app/CLI and `bpd`, the session daemon (PLAN §4.1).
/// Newline-delimited JSON over a Unix socket; terminal bytes travel base64-encoded.
public enum SessionProtocol {
    /// Bump on any incompatible change. A daemon with another version is replaced when it has no live sessions.
    public static let version = 2

    public static var defaultSocketPath: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bullpen/run", isDirectory: true)
        return base.appendingPathComponent("bpd.sock").path
    }

    /// Agent events of a session, one JSON `AgentActivity` per line (the worktree's log).
    public static func eventsFile(session: String, logDirectory: URL = defaultLogDirectory) -> URL {
        let safe = String(session.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return logDirectory.appendingPathComponent("\(safe).events.jsonl")
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bullpen/sessions", isDirectory: true)
    }
}

public struct SessionSpec: Codable, Sendable, Equatable {
    /// Stable id chosen by the caller (e.g. one per worktree) so it can find the session again after a restart.
    public var id: String
    public var cwd: String
    /// Command run through the user's login shell. `nil` starts an interactive login shell.
    public var command: String?
    public var environment: [String: String]
    public var cols: UInt16
    public var rows: UInt16

    public init(id: String, cwd: String, command: String? = nil, environment: [String: String] = [:], cols: UInt16 = 120, rows: UInt16 = 40) {
        self.id = id
        self.cwd = cwd
        self.command = command
        self.environment = environment
        self.cols = cols
        self.rows = rows
    }
}

/// Last lifecycle event reported by an agent's hooks (`bp hook`), e.g. Claude Code `PreToolUse`.
public struct AgentActivity: Codable, Sendable, Equatable {
    /// Agent profile id (`claude`, `codex`).
    public var agent: String
    /// Hook event name (`UserPromptSubmit`, `PreToolUse`, `Notification`, `Stop`, `agent-turn-complete`…).
    public var event: String
    /// Tool name, notification type or short message.
    public var detail: String?
    public var at: Date
    /// Human summary for the log: the prompt, the command run, the file edited, the final answer…
    public var summary: String?
    /// Claude Code's transcript (JSONL), used to add up token usage.
    public var transcriptPath: String?

    public init(agent: String, event: String, detail: String? = nil, at: Date = Date(),
                summary: String? = nil, transcriptPath: String? = nil) {
        self.agent = agent
        self.event = event
        self.detail = detail
        self.at = at
        self.summary = summary
        self.transcriptPath = transcriptPath
    }
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public var id: String
    public var cwd: String
    public var command: String?
    public var pid: Int32
    public var cols: UInt16
    public var rows: UInt16
    public var startedAt: Date
    /// Exit code (128 + signal when killed by a signal); nil while running.
    public var exitStatus: Int32?
    public var lastOutputAt: Date?
    public var agentActivity: AgentActivity?
    /// Name of the terminal's foreground process (`claude`, `zsh`…), filled in by `list`.
    public var foregroundProcess: String?
    /// The program turned on bracketed paste (`ESC[?2004h`), so multi-line text can be pasted safely.
    public var bracketedPaste: Bool?

    public var isRunning: Bool { exitStatus == nil }

    public init(id: String, cwd: String, command: String?, pid: Int32, cols: UInt16, rows: UInt16, startedAt: Date,
                exitStatus: Int32? = nil, lastOutputAt: Date? = nil, agentActivity: AgentActivity? = nil, foregroundProcess: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.command = command
        self.pid = pid
        self.cols = cols
        self.rows = rows
        self.startedAt = startedAt
        self.exitStatus = exitStatus
        self.lastOutputAt = lastOutputAt
        self.agentActivity = agentActivity
        self.foregroundProcess = foregroundProcess
    }
}

public enum ClientMessage: Codable, Sendable {
    case hello(request: Int, protocolVersion: Int)
    case create(request: Int, spec: SessionSpec)
    case list(request: Int)
    /// Replies `ok`, then a `snapshot` with recent output, then live `output` events.
    case attach(request: Int, session: String)
    case detach(session: String)
    case input(session: String, data: Data)
    case resize(session: String, cols: UInt16, rows: UInt16)
    case kill(request: Int, session: String, signal: Int32)
    /// Forget an exited session.
    case remove(request: Int, session: String)
    case shutdown(request: Int)
    /// Sent by `bp hook` from inside an agent's session.
    case agentEvent(request: Int, session: String, activity: AgentActivity)
}

public enum ServerMessage: Codable, Sendable {
    case hello(request: Int, protocolVersion: Int, build: String, pid: Int32)
    case created(request: Int, session: SessionInfo)
    case sessions(request: Int, sessions: [SessionInfo])
    case ok(request: Int)
    case error(request: Int, message: String)
    case snapshot(session: String, data: Data)
    case output(session: String, data: Data)
    case exited(session: String, status: Int32)
    /// Broadcast to every client when a session's agent reports activity.
    case activity(session: SessionInfo)
}

public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// Splits an incoming byte stream into newline-terminated frames.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
