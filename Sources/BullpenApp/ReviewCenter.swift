import BPAgents
import BPCore
import BPWorkspace
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Reviews of finished work: when a worktree's agent finishes and its PR is open, a reviewer
/// starts in the Reviews office (quick, or exhaustive from N changed files, per project). When
/// the review command ends it is asked for a verdict; its fixes wait, uncommitted, for the user.
@MainActor
@Observable
final class ReviewCenter {
    /// Newest reviewer of each reviewed worktree, for the badge on its row.
    private(set) var latest: [UUID: Worktree] = [:]
    /// Worktrees whose agent has just finished a turn (they may get a review once their PR is there).
    @ObservationIgnored private var finishedAt: [UUID: Date] = [:]
    @ObservationIgnored private var launching: Set<UUID> = []

    static let quickKey = "review.quickCommand"
    static let exhaustiveKey = "review.exhaustiveCommand"
    static let quickDefault = "--fix --loops=1 --stop-at=S1 --profile=cheap --budget=120k"
    static let exhaustiveDefault = "--fix --loops=until-clean --stop-at=S2 --profile=max --budget=800k"

    static func flags(_ kind: ReviewInfo.Kind) -> String {
        let key = kind == .quick ? quickKey : exhaustiveKey
        let saved = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces)
        return saved?.isEmpty == false ? saved! : (kind == .quick ? quickDefault : exhaustiveDefault)
    }

    /// Called when a worktree's agent reaches "done".
    func agentFinished(_ worktree: Worktree) {
        guard worktree.review == nil else { return }
        finishedAt[worktree.id] = Date()
    }

    func start(store: BuildingStore, sessions: SessionManager, attention: AttentionCenter, repoStatus: RepoStatusCenter) async {
        while !Task.isCancelled {
            await tick(store: store, sessions: sessions, attention: attention, repoStatus: repoStatus)
            await Pacing.pause(active: 10, background: 30)
        }
    }

    private func tick(store: BuildingStore, sessions: SessionManager, attention: AttentionCenter, repoStatus: RepoStatusCenter) async {
        guard let workspace = store.workspace else { return }
        let all = store.offices.flatMap(\.worktrees)
        let reviewers = all.filter { $0.review != nil }.sorted { $0.createdAt < $1.createdAt }
        let next = Dictionary(reviewers.map { ($0.review!.of, $0) }, uniquingKeysWith: { _, newer in newer })
        if next != latest { latest = next }

        // Reviewers moving on: review done → ask for the verdict → verdict in.
        for reviewer in reviewers {
            guard var info = reviewer.review, info.phase == .reviewing || info.phase == .summarizing,
                  attention.statuses[reviewer.id]?.state == .done,
                  let activity = sessions.infos[SessionManager.sessionID(for: reviewer)]?.agentActivity else { continue }
            if info.phase == .reviewing {
                do {
                    try await sessions.sendMessage(Self.verdictRequest, to: reviewer)
                    info.phase = .summarizing
                    info.summaryRequestedAt = Date()
                    try workspace.saveReview(info, for: reviewer)
                } catch {
                    continue
                }
            } else if let asked = info.summaryRequestedAt, activity.at > asked, let text = activity.summary {
                info.summary = text
                info.approved = ReviewInfo.verdict(in: text)
                info.phase = .done
                try? workspace.saveReview(info, for: reviewer)
                announce(reviewer, info: info)
            }
        }

        // New reviews for work that has just finished, once its PR is open.
        finishedAt = finishedAt.filter { Date().timeIntervalSince($0.value) < 600 }
        for (id, _) in finishedAt {
            guard let office = store.offices.first(where: { $0.worktrees.contains { $0.id == id } }),
                  !office.project.isReviews, office.project.reviewsAutomatically,
                  let worktree = office.worktrees.first(where: { $0.id == id }),
                  attention.statuses[id]?.state == .done,
                  let pr = repoStatus.pullRequests[id], pr.state == .open else { continue }
            finishedAt[id] = nil
            await review(worktree, in: office.project, kind: nil, pullRequest: pr.number, store: store, automatic: true)
        }
    }

    /// Starts a review of `worktree`. `kind` nil picks it by the project's rule (changed files).
    func review(_ worktree: Worktree, in project: Project, kind: ReviewInfo.Kind?, pullRequest: Int?,
                store: BuildingStore, automatic: Bool = false) async {
        guard let workspace = store.workspace, !launching.contains(worktree.id) else { return }
        launching.insert(worktree.id)
        defer { launching.remove(worktree.id) }
        do {
            let head = try await workspace.headCommit(of: worktree)
            let reviewers = store.offices.flatMap(\.worktrees).compactMap(\.review).filter { $0.of == worktree.id }
            if automatic {
                if try workspace.wasReviewed(worktree, at: head) { return }
                if reviewers.contains(where: { $0.phase == .reviewing || $0.phase == .summarizing }) { return }
            }
            var chosen = kind ?? .quick
            if kind == nil, project.exhaustiveReviewFrom > 0,
               let files = await workspace.changedFileCount(of: worktree), files >= project.exhaustiveReviewFrom {
                chosen = .exhaustive
            }
            try await workspace.createReview(of: worktree, in: project, kind: chosen, pullRequest: pullRequest,
                                             prompt: Self.prompt(chosen, worktree: worktree))
        } catch where automatic {
            BackgroundNotice.post(id: "review-\(worktree.id)", title: "No se pudo lanzar la revisión de \(worktree.branch)",
                                  body: error.localizedDescription, failure: true)
        } catch {
            store.errorMessage = "No se pudo lanzar la revisión de \(worktree.branch): \(error.localizedDescription)"
        }
    }

    /// The repository's `/review` skill when it has one; otherwise the same job in words (Claude
    /// Code's built-in `/review` is a different thing).
    static func prompt(_ kind: ReviewInfo.Kind, worktree: Worktree) -> String {
        if hasReviewSkill(in: worktree.path) {
            return "/review --base=\(worktree.baseRef) \(flags(kind))"
        }
        let depth = kind == .quick
            ? "Haz una revisión rápida: una pasada, céntrate en fallos graves (bugs, seguridad, datos)."
            : "Haz una revisión exhaustiva: repasa todo el cambio, arregla y vuelve a revisar hasta que no queden problemas importantes."
        return """
        Revisa el código de esta rama frente a \(worktree.baseRef) (git diff \(worktree.baseRef)...HEAD) antes de subirlo. \(depth) \
        Arregla directamente en los ficheros lo que encuentres, pero no hagas commit ni push: los cambios los valida una persona.
        """
    }

    static func hasReviewSkill(in path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(path)/.claude/skills/review/SKILL.md", "\(path)/.claude/commands/review.md",
            "\(home)/.claude/skills/review/SKILL.md", "\(home)/.claude/commands/review.md",
        ].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static let verdictRequest = """
    Ya has terminado la revisión. Resume el resultado en español para decidir si esta PR se puede subir. \
    La primera línea debe ser exactamente «VEREDICTO: SE PUEDE SUBIR» o «VEREDICTO: NO SE PUEDE SUBIR». \
    Después, en pocas líneas: por qué, qué has arreglado y qué queda pendiente. \
    Tus arreglos se quedan sin commit: no hagas commit ni push.
    """

    // MARK: Fixes

    /// Commits and pushes the reviewer's fixes to the PR. Returns what happened, for the user.
    func apply(_ reviewer: Worktree, store: BuildingStore) async -> String {
        guard let workspace = store.workspace else { return "" }
        do {
            let result = try await workspace.applyReviewFixes(reviewer)
            guard let commit = result.commit else { return "El revisor no ha cambiado nada: no hay arreglos que subir." }
            let original = result.updatedOriginal ? " El worktree original ya está al día." : " Actualiza el worktree original (git pull) antes de seguir en él."
            return "Arreglos subidos a \(reviewer.review?.branch ?? "la PR") (\(commit.prefix(7)))." + original
        } catch {
            return "No se pudieron subir los arreglos: \(error.localizedDescription)"
        }
    }

    // MARK: Notifications

    private func announce(_ reviewer: Worktree, info: ReviewInfo) {
        let content = UNMutableNotificationContent()
        switch info.approved {
        case true?: content.title = "\(reviewer.branch): se puede subir"
        case false?: content.title = "\(reviewer.branch): no se puede subir"
        case nil: content.title = "Revisión de \(reviewer.branch) terminada"
        }
        content.subtitle = info.kind == .quick ? "Revisión rápida" : "Revisión exhaustiva"
        content.body = (info.summary ?? "").split(separator: "\n").dropFirst().prefix(3).joined(separator: " ")
        content.threadIdentifier = info.of.uuidString
        content.sound = .default
        DoNotDisturb.shared.deliver(UNNotificationRequest(identifier: "review-\(reviewer.id.uuidString)", content: content, trigger: nil))
    }
}

/// A review's state next to a worktree: under way, can go up, can't, fixes applied.
struct ReviewBadge: View {
    let review: ReviewInfo

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: review.phase == .reviewing || review.phase == .summarizing)
            .help(help)
    }

    private var symbol: String {
        switch review.phase {
        case .reviewing, .summarizing: "magnifyingglass.circle"
        case .applied: "checkmark.seal.fill"
        case .done: review.approved == false ? "xmark.seal.fill" : review.approved == true ? "checkmark.seal.fill" : "seal"
        }
    }

    private var color: Color {
        switch review.phase {
        case .reviewing, .summarizing: .orange
        case .applied: .blue
        case .done: review.approved == false ? .red : review.approved == true ? .green : .secondary
        }
    }

    private var help: String {
        let kind = review.kind == .quick ? "Revisión rápida" : "Revisión exhaustiva"
        switch review.phase {
        case .reviewing: return "\(kind) en marcha"
        case .summarizing: return "\(kind): preparando el veredicto"
        case .applied: return "\(kind): arreglos subidos a la PR"
        case .done:
            let verdict = review.approved == false ? "no se puede subir" : review.approved == true ? "se puede subir" : "terminada"
            return "\(kind): \(verdict)" + (review.summary.map { "\n\n" + $0 } ?? "")
        }
    }
}

/// Top of a reviewer's window: what it reviews, its verdict, and accepting or discarding its fixes.
struct ReviewBanner: View {
    let reviewer: Worktree
    let review: ReviewInfo
    @Environment(BuildingStore.self) private var store
    @Environment(ReviewCenter.self) private var reviews
    @State private var working = false
    @State private var message: String?
    @State private var confirmingDiscard = false
    /// The reviewer left uncommitted changes; without them there is nothing to apply.
    @State private var hasFixes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ReviewBadge(review: review)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if review.phase == .done, hasFixes {
                    Button(working ? "Subiendo…" : "Aplicar arreglos") { Task { await apply() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(working)
                        .help("Hace commit de los cambios del revisor y los sube a la rama de la PR (\(review.branch))")
                }
                if review.phase == .done || review.phase == .applied {
                    Button(review.phase == .applied ? "Cerrar revisor" : "Descartar") { confirmingDiscard = true }
                        .controlSize(.small)
                        .disabled(working)
                }
            }
            if let summary = review.summary, review.phase == .done || review.phase == .applied {
                ScrollView {
                    Text(summary).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            } else if review.phase == .reviewing {
                Text("Revisando \(review.branch). Cuando termine le pediré el veredicto; sus arreglos quedarán sin commit para que los valides en Panel › Cambios.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
        // Re-checked while the review is done: you can still ask the reviewer for changes.
        .task(id: review.phase) {
            while review.phase == .done, !Task.isCancelled {
                hasFixes = await store.workspace?.hasReviewFixes(reviewer) ?? false
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(review.phase == .applied ? "¿Cerrar este revisor?" : "¿Descartar la revisión y sus arreglos?",
                            isPresented: $confirmingDiscard) {
            Button(review.phase == .applied ? "Cerrar" : "Descartar", role: .destructive) {
                Task { await discard() }
            }
        } message: {
            Text(review.phase == .applied ? "Sus arreglos ya están en la PR." : "Se borra su carpeta; los cambios sin commit se pierden.")
        }
    }

    private var title: String {
        let kind = review.kind == .quick ? "Revisión rápida" : "Revisión exhaustiva"
        let pr = review.pullRequest.map { " · PR #\($0)" } ?? ""
        switch review.phase {
        case .reviewing: return "\(kind) de \(review.branch)\(pr)"
        case .summarizing: return "\(kind) de \(review.branch)\(pr) · preparando el veredicto"
        case .applied: return "\(kind) de \(review.branch)\(pr) · arreglos subidos"
        case .done:
            let verdict = review.approved == false ? "no se puede subir" : review.approved == true ? "se puede subir" : "terminada"
            return "\(kind) de \(review.branch)\(pr) · \(verdict)"
        }
    }

    private func apply() async {
        working = true
        defer { working = false }
        message = await reviews.apply(reviewer, store: store)
    }

    private func discard() async {
        guard let project = store.offices.first(where: { $0.project.isReviews })?.project else { return }
        working = true
        defer { working = false }
        await store.removeWorktree(reviewer, in: project, force: true)
    }
}
