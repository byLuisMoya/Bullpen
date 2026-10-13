import BPGit
import SwiftUI

/// Orca's branch/PR glyph: PR state when there is one (open tinted by checks, draft, merged,
/// closed), otherwise the branch glyph, dimmed while the branch only exists locally.
struct BranchBadge: View {
    let branch: String
    let sync: BranchSync?
    let pullRequest: PullRequest?
    @State private var hovering = false
    @State private var cardShown = false

    var body: some View {
        HStack(spacing: 3) {
            if let ahead = sync?.ahead, ahead > 0, pullRequest?.state != .merged {
                Text("↑\(ahead)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GitGlyphView(glyph: glyph, color: color)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = pullRequest?.url { NSWorkspace.shared.open(url) }
        }
        // A card like GitHub's after a short hover: PR number, branch, state.
        .onHover { inside in
            hovering = inside
            if inside {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if hovering { cardShown = true }
                }
            } else {
                cardShown = false
            }
        }
        .popover(isPresented: $cardShown, arrowEdge: .trailing) { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                GitGlyphView(glyph: glyph, color: color)
                Text(pullRequest.map { "PR #\($0.number)" } ?? "Rama")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(pullRequest?.branch ?? branch)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                pill(stateLabel, color: color)
                if let checks = checksLabel { pill(checks, color: color) }
            }
            if let sync, pullRequest?.state != .merged, sync.ahead > 0 || sync.behind > 0 {
                Text([sync.ahead > 0 ? "\(sync.ahead) commit(s) sin subir" : nil,
                      sync.behind > 0 ? "\(sync.behind) nuevo(s) en remoto" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pullRequest?.url != nil {
                Text("Clic en el icono para abrirla en GitHub").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.7)))
    }

    private var stateLabel: String {
        guard let pr = pullRequest else {
            guard let sync else { return "Estado: desconocido" }
            return sync.isPushed ? "Estado: subida" : "Estado: solo en local"
        }
        return switch pr.state {
        case .open: "Estado: Abierto"
        case .draft: "Estado: Borrador"
        case .merged: "Estado: Fusionado"
        case .closed: "Estado: Cerrado"
        }
    }

    private var checksLabel: String? {
        guard let pr = pullRequest, pr.state == .open else { return nil }
        return switch pr.checks {
        case .failure: "Checks fallando"
        case .pending: "Checks en curso"
        case .success: "Checks pasando"
        case .none: nil
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
}
