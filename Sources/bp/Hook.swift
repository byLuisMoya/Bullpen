import ArgumentParser
import BPSessions
import Foundation

/// Called by agent hooks (Claude Code / Codex) running inside a Bullpen session.
/// Forwards the event to bpd and always exits 0 quickly, so it can never slow down or break the agent.
struct Hook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Forward an agent lifecycle event to bpd (used by agent hooks).",
        shouldDisplay: false
    )

    @Argument(help: "Agent id: claude or codex.") var agent: String
    @Argument(parsing: .captureForPassthrough, help: "Codex notify passes the event JSON here.") var rest: [String] = []

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = env["BULLPEN_SESSION_ID"] else { return }
        let socket = env["BULLPEN_SOCKET"] ?? SessionProtocol.defaultSocketPath

        let payload = rest.last.flatMap { $0.hasPrefix("{") ? Data($0.utf8) : nil } ?? readStdin()
        guard let activity = Self.activity(agent: agent, payload: payload) else { return }

        // Give up after a second: a hook must never hang the agent.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                guard let client = try? SessionClient.connect(socketPath: socket) else { return }
                try? await client.reportAgentEvent(session, activity)
                client.close()
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func readStdin() -> Data? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    }

    /// Extracts event name and a short detail from a Claude/Codex hook payload or a Codex notify payload.
    static func activity(agent: String, payload: Data?) -> AgentActivity? {
        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        guard let event = (json["hook_event_name"] ?? json["hookEventName"] ?? json["type"]) as? String else { return nil }
        let detail = (json["tool_name"] ?? json["toolName"] ?? json["notification_type"] ?? json["error_type"]) as? String
        return AgentActivity(agent: agent, event: event, detail: detail)
    }
}
