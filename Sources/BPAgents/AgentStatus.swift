import BPCore
import BPSessions
import Foundation

/// How sure we are about a state (PLAN §8.1): hooks are high, heuristics are low.
public enum StatusConfidence: Int, Sendable, Comparable {
    case low, medium, high
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct AgentStatus: Equatable, Sendable {
    public var state: AgentState
    /// Short human text: tool in use, what it is waiting for…
    public var detail: String?
    public var confidence: StatusConfidence
    public var since: Date?

    public init(state: AgentState, detail: String? = nil, confidence: StatusConfidence, since: Date? = nil) {
        self.state = state
        self.detail = detail
        self.confidence = confidence
        self.since = since
    }
}

/// Pure rules turning what `bpd` knows about a session into an `AgentState` (PLAN §8, "the state never lies").
public enum StatusEngine {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "nu", "-zsh", "-bash"]

    public static func isShell(_ process: String) -> Bool { shells.contains(process) }

    public static func status(for session: SessionInfo?, profile: AgentProfile?, now: Date = Date()) -> AgentStatus {
        guard let session else { return AgentStatus(state: .unknown, detail: nil, confidence: .low, since: nil) }
        if let code = session.exitStatus {
            return AgentStatus(state: .dead, detail: "terminal cerrada (código \(code))", confidence: .high, since: nil)
        }
        let outputRecently = session.lastOutputAt.map { now.timeIntervalSince($0) < 3 } ?? false

        // Terminal without an agent.
        guard let profile else {
            return AgentStatus(state: outputRecently ? .working : .idle, detail: nil, confidence: .low, since: session.lastOutputAt)
        }

        let age = now.timeIntervalSince(session.startedAt)
        let foreground = session.foregroundProcess
        // Back at the shell prompt: the agent is not running any more.
        if let foreground, shells.contains(foreground), age > 5 {
            return AgentStatus(state: .dead, detail: "no está en ejecución", confidence: .medium, since: nil)
        }

        guard let activity = session.agentActivity else {
            if age < 15 { return AgentStatus(state: .starting, detail: nil, confidence: .medium, since: session.startedAt) }
            return AgentStatus(state: outputRecently ? .working : .unknown, detail: nil, confidence: .low, since: session.lastOutputAt)
        }

        var status = fromHook(activity)
        // A working/thinking state with no fresh hook or output for a long time is not trustworthy.
        if status.state == .working || status.state == .thinking {
            let lastSign = max(activity.at, session.lastOutputAt ?? .distantPast)
            if now.timeIntervalSince(lastSign) > 600 {
                status = AgentStatus(state: .unknown, detail: "sin señales desde hace más de 10 min", confidence: .low, since: lastSign)
            }
        }
        return status
    }

    static func fromHook(_ a: AgentActivity) -> AgentStatus {
        func make(_ state: AgentState, _ detail: String? = nil) -> AgentStatus {
            AgentStatus(state: state, detail: detail, confidence: .high, since: a.at)
        }
        switch a.event {
        case "SessionStart": return make(.idle, "esperando instrucciones")
        case "UserPromptSubmit": return make(.thinking)
        case "PreToolUse": return make(.working, a.detail.map { "usando \($0)" })
        case "PostToolUse", "PostToolUseFailure": return make(.thinking)
        case "PermissionRequest": return make(.needsYou, a.detail.map { "pide permiso para \($0)" } ?? "pide permiso")
        case "Notification":
            switch a.detail {
            case "idle_prompt", "agent_completed": return make(.done)
            case "auth_success", "elicitation_complete", "elicitation_response": return make(.thinking)
            default: return make(.needsYou, "te necesita")
            }
        case "Stop", "agent-turn-complete": return make(.done, "terminado")
        case "StopFailure": return make(.error, a.detail ?? "error de la API")
        case "Interrupt": return make(.idle, "interrumpido")
        case "SessionEnd": return make(.dead, "sesión terminada")
        default: return AgentStatus(state: .unknown, detail: a.event, confidence: .low, since: a.at)
        }
    }
}
