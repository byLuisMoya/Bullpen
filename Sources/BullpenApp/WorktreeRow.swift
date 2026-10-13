import BPAgents
import BPCore
import BPGit
import SwiftUI

struct WorktreeRow: View {
    let worktree: Worktree
    let status: AgentStatus?
    var sync: BranchSync?
    var pullRequest: PullRequest?
    var warning: WorktreeWarning?
    /// What the agent is doing, in a few words (SummaryCenter).
    var summary: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status?.state.symbol ?? "circle.dotted")
                .foregroundStyle(status?.state.color ?? .secondary)
                .symbolEffect(.pulse, isActive: status?.state == .needsYou)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.branch).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let warning {
                Image(systemName: warning.isConflict ? "bolt.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(warning.isConflict ? Color.red : Color.yellow)
                    .help(warning.tooltip)
            }
            BranchBadge(sync: sync, pullRequest: pullRequest)
        }
        .help(status.map { "\($0.state.label) · confianza \($0.confidence)" } ?? "")
    }

    private var subtitle: String {
        let agent = AgentProfile.named(worktree.agentProfileID)?.name ?? "Terminal"
        if let summary, let state = status?.state, SummaryCenter.activeStates.contains(state), state != .needsYou {
            return "\(agent) · \(summary)"
        }
        let state = status.map { $0.detail ?? $0.state.label } ?? "—"
        return "\(agent) · \(state)"
    }
}

extension AgentState {
    var label: String {
        switch self {
        case .starting: "arrancando"
        case .thinking: "pensando"
        case .working: "trabajando"
        case .needsYou: "te necesita"
        case .done: "listo para revisar"
        case .idle: "en espera"
        case .error: "error"
        case .dead: "parado"
        case .unknown: "estado desconocido"
        }
    }

    var symbol: String {
        switch self {
        case .starting: "circle.dotted"
        case .thinking: "ellipsis.circle"
        case .working: "gearshape.fill"
        case .needsYou: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "moon.zzz"
        case .error: "exclamationmark.triangle.fill"
        case .dead: "chair"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: .orange
        case .error: .red
        case .done: .green
        case .working, .thinking, .starting: .blue
        case .idle, .dead, .unknown: .secondary
        }
    }
}
