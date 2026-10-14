import BPAgents
import BPCore
import BPWorkspace
import Foundation
import Observation

/// What Orca's own agents are doing in the worktrees that came from Orca, so their people in
/// the office work, wait, finish and talk like the ones Bullpen runs.
@MainActor
@Observable
final class OrcaCenter {
    private(set) var activity: [String: OrcaActivity] = [:]
    /// `Workspace.canonical` touches the disk; worktree paths don't change, so once per path.
    @ObservationIgnored private var canonicalPaths: [String: String] = [:]

    func start(store: BuildingStore) async {
        guard OrcaWorktree.locate() != nil else { return }
        while !Task.isCancelled {
            // `orca worktree ps` is a whole CLI run: only while some worktree from outside has no
            // agent of Bullpen's (once it has one, its state is Bullpen's own and this isn't read).
            if store.offices.contains(where: { $0.worktrees.contains { $0.external && $0.agentProfileID == nil } }) {
                let rows = await OrcaActivity.list()
                let next = Dictionary(rows.map { (Workspace.canonical($0.path), $0) }, uniquingKeysWith: { a, _ in a })
                if next != activity { activity = next }
            } else if !activity.isEmpty {
                activity = [:]
            }
            await Pacing.pause(active: 4, background: 15)
        }
    }

    /// Orca's view of a worktree made there, while Bullpen has no terminal of its own in it.
    func activity(for worktree: Worktree) -> OrcaActivity? {
        guard worktree.external, !activity.isEmpty else { return nil }
        return activity[canonical(worktree.path)]
    }

    private func canonical(_ path: String) -> String {
        if let known = canonicalPaths[path] { return known }
        let resolved = Workspace.canonical(path)
        canonicalPaths[path] = resolved
        return resolved
    }

    func status(for worktree: Worktree) -> AgentStatus? {
        guard let orca = activity(for: worktree) else { return nil }
        let state = orca.state()
        let label = [orca.agentType.map { $0.capitalized }, orca.agentState].compactMap { $0 }.joined(separator: " · ")
        // The row already says "Orca": just its agent and state.
        return AgentStatus(state: state, detail: label.isEmpty ? "abierto en Orca" : label,
                           confidence: .medium, since: orca.lastOutputAt)
    }
}
