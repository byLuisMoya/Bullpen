import BPAgents
import BPCore
import BPHabitat
import BPPersistence
import SwiftUI

/// "El Edificio": one office per project, stacked like floors in the sidebar order (PLAN §9).
struct BuildingView: View {
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention
    var onSelect: (UUID) -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.offices) { office in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: office.lighting == .off ? "lightbulb" : "lightbulb.fill")
                                .foregroundStyle(office.lighting == .off ? Color.secondary : Color.yellow)
                            Text(office.project.name).font(.headline)
                            Text(summary(office)).font(.caption).foregroundStyle(.secondary)
                        }
                        OfficeFloor(model: model(for: office), onSelect: onSelect)
                            .frame(
                                width: OfficeLayer.preferredWidth(desks: max(office.worktrees.count, 4)),
                                height: OfficeLayer.preferredHeight(desks: office.worktrees.count)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func model(for office: Office) -> OfficeModel {
        OfficeModel(desks: office.worktrees.map { worktree in
            let status = attention.statuses[worktree.id]
            return DeskModel(
                id: worktree.id,
                name: worktree.branch,
                state: status?.state ?? .unknown,
                detail: status.map { $0.detail ?? $0.state.label },
                look: .make(worktreeID: worktree.id, agent: worktree.agentProfileID)
            )
        })
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

private struct OfficeFloor: NSViewRepresentable {
    let model: OfficeModel
    let onSelect: (UUID) -> Void

    func makeNSView(context: Context) -> OfficeView {
        let view = OfficeView(frame: .zero)
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ view: OfficeView, context: Context) {
        view.onSelect = onSelect
        view.update(model)
    }
}
