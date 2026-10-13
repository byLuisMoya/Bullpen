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

    func start() async {
        guard OrcaWorktree.locate() != nil else { return }
        while !Task.isCancelled {
            let rows = await OrcaActivity.list()
            activity = Dictionary(rows.map { (Workspace.canonical($0.path), $0) }, uniquingKeysWith: { a, _ in a })
            try? await Task.sleep(for: .seconds(4))
        }
    }

    /// Orca's view of a worktree made there, while Bullpen has no terminal of its own in it.
    func activity(for worktree: Worktree) -> OrcaActivity? {
        guard worktree.external else { return nil }
        return activity[Workspace.canonical(worktree.path)]
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
