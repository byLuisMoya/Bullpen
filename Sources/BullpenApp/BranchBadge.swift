import BPGit
import SwiftUI

/// Orca's branch/PR glyph: PR state when there is one (open tinted by checks, draft, merged,
/// closed), otherwise the branch glyph, dimmed while the branch only exists locally.
struct BranchBadge: View {
    let sync: BranchSync?
    let pullRequest: PullRequest?

    var body: some View {
        HStack(spacing: 3) {
            if let ahead = sync?.ahead, ahead > 0, pullRequest?.state != .merged {
                Text("↑\(ahead)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GitGlyphView(glyph: glyph, color: color)
        }
        .help(tooltip)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = pullRequest?.url { NSWorkspace.shared.open(url) }
        }
    }

    private var glyph: GitGlyph {
        switch pullRequest?.state {
        case .open: .pullRequest
        case .draft: .pullRequestDraft
        case .merged: .merge
        case .closed: .pullRequestClosed
        case nil: .branch
        }
    }

    private var color: Color {
        guard let pr = pullRequest else {
            return Color.secondary.opacity(sync?.isPushed == true ? 0.75 : 0.4)
        }
        switch pr.state {
        case .merged: return Color(red: 0.58, green: 0.2, blue: 0.92).opacity(0.75)   // purple
        case .closed: return Color.secondary.opacity(0.6)
        case .draft: return Color.secondary.opacity(0.5)
        case .open:
            switch pr.checks {
            case .failure: return Color(red: 0.96, green: 0.25, blue: 0.37).opacity(0.85)   // rose
            case .pending: return Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.85)   // amber
            case .success, .none: return Color(red: 0.06, green: 0.73, blue: 0.51).opacity(0.8)  // emerald
            }
        }
    }

    private var tooltip: String {
        if let pr = pullRequest {
            let state = switch pr.state {
            case .open: "abierta"
            case .draft: "borrador"
            case .merged: "fusionada"
            case .closed: "cerrada"
            }
            var text = "PR #\(pr.number) \(state)"
            if pr.state == .open {
                switch pr.checks {
                case .failure: text += " · checks fallando"
                case .pending: text += " · checks en curso"
                case .success: text += " · checks pasando"
                case .none: break
                }
            }
            return text + " — clic para abrirla"
        }
        guard let sync else { return "Rama" }
        guard sync.isPushed else { return "Rama solo en local (sin subir)" }
        var text = "Rama subida"
        if sync.ahead > 0 { text += " · \(sync.ahead) commit(s) sin subir" }
        if sync.behind > 0 { text += " · \(sync.behind) commit(s) nuevos en remoto" }
        return text
    }
}
