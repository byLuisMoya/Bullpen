import BPAgents
import BPCore
import BPHabitat
import BPPersistence
import SwiftUI

/// "El Edificio": one office per project, stacked like floors in the sidebar order (PLAN §9).
struct BuildingView: View {
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention
    @Environment(RepoStatusCenter.self) private var repoStatus
    var onSelect: (UUID) -> Void
    @State private var removingDemo = false

    var body: some View {
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
                            OfficeFloor(model: officeModel(office, statuses: attention.statuses, warnings: repoStatus.warnings), compact: false, onSelect: onSelect)
                                .containerRelativeFrame(.horizontal) { visible, _ in
                                    max(visible, OfficeLayer.preferredWidth(desks: office.worktrees.count))
                                }
                                .frame(height: OfficeLayer.preferredHeight(desks: office.worktrees.count))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding()
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

func officeModel(_ office: Office, statuses: [UUID: AgentStatus], warnings: [UUID: WorktreeWarning] = [:]) -> OfficeModel {
    OfficeModel(desks: office.worktrees.map { worktree in
        let status = statuses[worktree.id]
        return DeskModel(
            id: worktree.id,
            name: worktree.ticket?.key ?? worktree.branch,
            state: status?.state ?? .unknown,
            detail: status.map { $0.detail ?? $0.state.label },
            look: .make(worktreeID: worktree.id, agent: worktree.agentProfileID),
            warning: warnings[worktree.id].map { $0.isConflict ? .conflict : .overlap }
        )
    })
}

/// The office strip shown above each project's worktrees in the sidebar. A plain SwiftUI image
/// (no AppKit layers) so it clips and animates with the sidebar; tap a person to open the worktree.
struct MiniOffice: View {
    let office: Office
    let onSelect: (UUID) -> Void
    @Environment(AttentionCenter.self) private var attention
    @Environment(RepoStatusCenter.self) private var repoStatus
    @State private var available: CGFloat = 0

    var body: some View {
        let model = officeModel(office, statuses: attention.statuses, warnings: repoStatus.warnings)
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
                if model.desks.indices.contains(slot) { onSelect(model.desks[slot].id) }
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
