import BPAgents
import BPCore
import BPGit
import BPHabitat
import BPPersistence
import SwiftUI

/// "El Edificio": one office per project, stacked like floors in the sidebar order (PLAN §9).
struct BuildingView: View {
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention
    @Environment(RepoStatusCenter.self) private var repoStatus
    @Environment(Navigation.self) private var navigation
    @Environment(SummaryCenter.self) private var summaries
    var onSelect: (UUID) -> Void
    @State private var removingDemo = false
    /// The office just opened from the sidebar, outlined for a moment.
    @State private var highlighted: UUID?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if AppActions.demoAvailable, store.offices.contains(where: { $0.project.path.hasPrefix("/tmp/bullpen-demo") || $0.project.path.hasPrefix("/private/tmp/bullpen-demo") }) {
                    HStack {
                        Label("Estás viendo la demo: los agentes son simulados.", systemImage: "theatermasks")
                        Spacer()
                        Button(removingDemo ? "Quitando…" : "Quitar demo") {
                            Task {
                                removingDemo = true
                                do { try await AppActions.demo("stop") } catch { store.errorMessage = error.localizedDescription }
                                removingDemo = false
                            }
                        }
                        .disabled(removingDemo)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(store.offices) { office in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: office.lighting == .off ? "lightbulb" : "lightbulb.fill")
                                .foregroundStyle(office.lighting == .off ? Color.secondary : Color.yellow)
                            Text(office.project.name).font(.headline)
                            Text(summary(office)).font(.caption).foregroundStyle(.secondary)
                        }
                        // Each floor fills the window's width and scrolls sideways on its own when
                        // its desks need more room.
                        ScrollView(.horizontal) {
                            OfficeFloor(model: officeModel(office, statuses: attention.statuses, warnings: repoStatus.warnings,
                                                           summaries: summaries.summaries, turns: repoStatus.turns,
                                                           pullRequests: repoStatus.pullRequests), compact: false, onSelect: onSelect)
                                .containerRelativeFrame(.horizontal) { visible, _ in
                                    max(visible, OfficeLayer.preferredWidth(desks: office.worktrees.count))
                                }
                                .frame(height: OfficeLayer.preferredHeight(desks: office.worktrees.count))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .opacity(highlighted == office.project.id ? 1 : 0)
                        }
                    }
                    .id(office.project.id)
                }
            }
            .padding()
        }
        .task(id: navigation.officeRequest?.id) {
            guard let project = navigation.officeRequest?.project else { return }
            // Let the building lay out first when it has just replaced a worktree view.
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(project, anchor: .top)
                highlighted = project
            }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
        }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func summary(_ office: Office) -> String {
        let states = office.worktrees.compactMap { attention.statuses[$0.id]?.state }
        var parts = ["\(office.worktrees.count) worktree\(office.worktrees.count == 1 ? "" : "s")"]
        let waiting = states.filter { $0 == .needsYou }.count
        let done = states.filter { $0 == .done }.count
        if waiting > 0 { parts.append("✋ \(waiting)") }
        if done > 0 { parts.append("✓ \(done)") }
        return parts.joined(separator: " · ")
    }
}

/// How long someone waits at the desk with nothing to do before leaving their jacket and going.
let awayAfter: TimeInterval = 60

func officeModel(_ office: Office, statuses: [UUID: AgentStatus], warnings: [UUID: WorktreeWarning] = [:],
                 summaries: [UUID: String] = [:], turns: [UUID: Int] = [:], pullRequests: [UUID: PullRequest] = [:],
                 now: Date = Date()) -> OfficeModel {
    let looks = CharacterLook.distinctJackets(office.worktrees.map { .make(worktreeID: $0.id, agent: $0.agentProfileID) })
    let theme = OfficeTheme(rawValue: office.project.officeTheme ?? "") ?? .basic
    return OfficeModel(desks: zip(office.worktrees, looks).map { worktree, look in
        let status = statuses[worktree.id]
        // Statuses refresh every second, so this flips on its own once the minute has passed.
        let away = status?.state == .idle && status?.since.map { now.timeIntervalSince($0) >= awayAfter } == true
        return DeskModel(
            id: worktree.id,
            name: worktree.ticket?.key ?? worktree.branch,
            state: status?.state ?? .unknown,
            detail: away ? "se ha ido: esperando instrucciones" : status.map { $0.detail ?? $0.state.label },
            look: look,
            warning: warnings[worktree.id].map { $0.isConflict ? .conflict : .overlap },
            away: away,
            summary: summaries[worktree.id],
            turns: turns[worktree.id] ?? 0,
            merged: pullRequests[worktree.id]?.state == .merged
        )
    }, theme: theme)
}

/// The office strip shown above each project's worktrees in the sidebar. A plain SwiftUI image
/// (no AppKit layers) so it clips and animates with the sidebar; tap a person to open the
/// worktree, anywhere else to see the office in the building.
struct MiniOffice: View {
    let office: Office
    let onSelect: (UUID) -> Void
    let onOpen: () -> Void
    @Environment(AttentionCenter.self) private var attention
    @Environment(RepoStatusCenter.self) private var repoStatus
    @State private var available: CGFloat = 0

    var body: some View {
        let model = officeModel(office, statuses: attention.statuses, warnings: repoStatus.warnings,
                                turns: repoStatus.turns, pullRequests: repoStatus.pullRequests)
        let desks = office.worktrees.count
        let natural = OfficeView.size(desks: desks, compact: true)
        // The room fills the sidebar's width; with more desks than fit, the strip scrolls sideways.
        let width = max(natural.width, available.rounded(.down))
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if let image = OfficeSnapshot.image(model, desks: desks, width: width) {
                    Image(decorative: image, scale: 2).interpolation(.none)
                } else {
                    Color.clear
                }
            }
            .frame(width: width, height: natural.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let slot = Int((location.x - 8) / 34)          // art margin and desk width, 1 pt per art pixel
                if location.x >= 8, model.desks.indices.contains(slot) { onSelect(model.desks[slot].id) } else { onOpen() }
            }
        }
        .frame(width: available > 0 ? available : natural.width, height: natural.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

struct OfficeFloor: NSViewRepresentable {
    let model: OfficeModel
    let compact: Bool
    let onSelect: (UUID) -> Void

    func makeNSView(context: Context) -> OfficeView {
        let view = OfficeView(frame: .zero, compact: compact)
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ view: OfficeView, context: Context) {
        view.onSelect = onSelect
        view.update(model)
    }
}
