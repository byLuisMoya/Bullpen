import BPCore
import SwiftUI

/// The panel on the right of a worktree: its files, what changed and the session log.
struct WorktreePanel: View {
    let worktree: Worktree
    let project: Project
    @Environment(ReviewNotes.self) private var notes
    @AppStorage("worktreePanel.tab") private var tab = ProcessInfo.processInfo.environment["BULLPEN_SNAPSHOT_TAB"] ?? Tab.changes.rawValue

    enum Tab: String { case files, changes, log, compare }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                Text("Ficheros").tag(Tab.files.rawValue)
                Text(changesLabel).tag(Tab.changes.rawValue)
                Text("Bitácora").tag(Tab.log.rawValue)
                if worktree.runID != nil { Text("Comparar").tag(Tab.compare.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            Group {
                switch Tab(rawValue: tab) ?? .changes {
                case .files: FilesView(worktree: worktree, project: project)
                case .changes: ReviewView(worktree: worktree, project: project)
                case .log: SessionLogView(worktree: worktree)
                case .compare:
                    if let runID = worktree.runID { RunCompareView(runID: runID, project: project) } else { ReviewView(worktree: worktree, project: project) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var changesLabel: String {
        let count = notes.comments[worktree.id]?.count ?? 0
        return count > 0 ? "Cambios (\(count))" : "Cambios"
    }
}
