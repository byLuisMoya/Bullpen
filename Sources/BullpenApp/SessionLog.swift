import BPAgents
import BPCore
import BPSessions
import BPWorkspace
import SwiftUI

/// The worktree's log: what the agent was asked, what it ran or edited, how each turn ended
/// (PLAN §11.4, "prompts are not a record").
enum SessionLog {
    static func events(for worktree: Worktree) -> [AgentActivity] {
        let url = SessionProtocol.eventsFile(session: Workspace.sessionID(for: worktree))
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Wire.decoder.decode(AgentActivity.self, from: Data($0)) }
    }

    /// Collapsible Markdown section for a PR description.
    static func markdown(for worktree: Worktree) -> String? {
        let events = events(for: worktree)
        guard !events.isEmpty else { return nil }
        var text = "<details>\n<summary>Bitácora del agente</summary>\n\n"
        let prompts = events.filter { $0.event == "UserPromptSubmit" }.compactMap(\.summary)
        if !prompts.isEmpty {
            text += "**Instrucciones**\n\n" + prompts.enumerated().map { "\($0 + 1). \($1.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\n\n"
        }
        let tools = Dictionary(grouping: events.filter { $0.event == "PreToolUse" }.compactMap(\.detail), by: { $0 }).mapValues(\.count)
        if !tools.isEmpty {
            text += "**Herramientas**: " + tools.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + "\n\n"
        }
        let commands = events.filter { $0.event == "PreToolUse" && $0.detail == "Bash" }.compactMap(\.summary)
        if !commands.isEmpty {
            text += "**Comandos**\n\n```\n" + commands.suffix(30).joined(separator: "\n") + "\n```\n\n"
        }
        text += "</details>\n"
        return text
    }
}

struct SessionLogView: View {
    let worktree: Worktree
    @State private var events: [AgentActivity] = []

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("Sin actividad registrada", systemImage: "list.bullet.rectangle",
                                       description: Text("La bitácora se llena con los avisos del agente (Claude Code, Codex y OpenCode)."))
            } else {
                List(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.symbol(event)).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(event)).font(.callout.bold())
                            if let summary = event.summary {
                                Text(summary).font(.system(.callout, design: event.event == "PreToolUse" ? .monospaced : .default))
                                    .textSelection(.enabled).lineLimit(6)
                            }
                        }
                        Spacer()
                        Text(event.at, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: worktree.id) {
            while !Task.isCancelled {
                events = SessionLog.events(for: worktree)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static func title(_ e: AgentActivity) -> String {
        switch e.event {
        case "SessionStart": "Sesión iniciada"
        case "UserPromptSubmit": "Instrucción"
        case "PreToolUse": e.detail.map { "Usa \($0)" } ?? "Usa una herramienta"
        case "PostToolUse": "Herramienta terminada"
        case "PostToolUseFailure": "La herramienta falló"
        case "PermissionRequest": "Pide permiso" + (e.detail.map { " para \($0)" } ?? "")
        case "Notification": "Aviso"
        case "Stop", "agent-turn-complete": "Turno terminado"
        case "StopFailure": "Error"
        case "SessionEnd": "Sesión terminada"
        default: e.event
        }
    }

    static func symbol(_ e: AgentActivity) -> String {
        switch e.event {
        case "UserPromptSubmit": "text.bubble"
        case "PreToolUse", "PostToolUse": "hammer"
        case "PermissionRequest", "Notification": "hand.raised"
        case "Stop", "agent-turn-complete": "checkmark.circle"
        case "StopFailure", "PostToolUseFailure": "exclamationmark.triangle"
        default: "circle"
        }
    }
}
