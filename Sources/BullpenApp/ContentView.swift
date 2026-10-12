import BPCore
import BPGit
import BPPersistence
import BPWorkspace
import SwiftUI

struct ContentView: View {
    @Environment(BuildingStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AttentionCenter.self) private var attention
    @Environment(RepoStatusCenter.self) private var repoStatus
    @Environment(Navigation.self) private var navigation
    @State private var editingPromptFor: Project?
    @State private var isImporting = false
    @State private var newWorktreeFor: Project?
    @State private var pendingRemoval: PendingRemoval?

    private var selection: UUID? {
        get { navigation.selection }
        nonmutating set { navigation.selection = newValue }
    }

    var body: some View {
        @Bindable var store = store
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(store.offices) { office in
                    Section {
                        MiniOffice(office: office) { selection = $0 }
                            .selectionDisabled()
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        ForEach(office.worktrees) { worktree in
                            WorktreeRow(
                                worktree: worktree, status: attention.statuses[worktree.id],
                                sync: repoStatus.branches[worktree.id], pullRequest: repoStatus.pullRequests[worktree.id],
                                warning: repoStatus.warnings[worktree.id]
                            )
                                .tag(worktree.id)
                                .contextMenu {
                                    Button("Mostrar en Finder") {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                                    }
                                    Button("Eliminar worktree…", role: .destructive) {
                                        Task { await confirmRemoval(worktree, in: office.project) }
                                    }
                                }
                        }
                    } header: {
                        OfficeHeader(office: office) { newWorktreeFor = office.project }
                            .contextMenu {
                                Button("Nuevo worktree…") { newWorktreeFor = office.project }
                                Button("Prompt inicial…") { editingPromptFor = office.project }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button("Edificio", systemImage: "building.2") { selection = nil }
                    .help("Ver todas las oficinas (⌘0)")
                    .keyboardShortcut("0", modifiers: .command)
                Button("Añadir proyecto", systemImage: "plus") { isImporting = true }
            }
        } detail: {
            if let (worktree, project) = selectedWorktree {
                WorktreeDetail(worktree: worktree, project: project)
                    .id(worktree.id)
                    .navigationTitle(worktree.branch)
                    .navigationSubtitle(worktree.path)
            } else if store.offices.isEmpty {
                ContentUnavailableView(
                    "Edificio vacío",
                    systemImage: "building.2",
                    description: Text("Añade un repositorio git para abrir su oficina.")
                )
            } else {
                BuildingView { selection = $0 }
                    .navigationTitle("Edificio")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                Task { await store.addProject(at: url) }
            }
        }
        .sheet(item: $newWorktreeFor) { project in
            NewWorktreeSheet(project: project) { selection = $0.id }
        }
        .sheet(item: $editingPromptFor) { project in
            ProjectPromptSheet(project: project)
        }
        .onChange(of: selection) { _, id in attention.focusedWorktree = id }
        .alert(
            "¿Eliminar \(pendingRemoval?.worktree.branch ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { removal in
            Button(removal.guards.isEmpty && !removal.hasLiveSession ? "Eliminar" : "Eliminar igualmente", role: .destructive) {
                Task {
                    if selection == removal.worktree.id { selection = nil }
                    await store.removeWorktree(removal.worktree, in: removal.project, force: !removal.guards.isEmpty)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
        .alert(
            "Algo ha fallado",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var selectedWorktree: (Worktree, Project)? {
        for office in store.offices {
            if let worktree = office.worktrees.first(where: { $0.id == selection }) { return (worktree, office.project) }
        }
        return nil
    }

    private func confirmRemoval(_ worktree: Worktree, in project: Project) async {
        let guards = await store.removalGuards(for: worktree, in: project)
        let live = await sessions.hasRunningSession(worktree)
        pendingRemoval = PendingRemoval(worktree: worktree, project: project, guards: guards, hasLiveSession: live)
    }
}

private struct PendingRemoval {
    var worktree: Worktree
    var project: Project
    var guards: [RemovalGuard]
    var hasLiveSession: Bool

    var message: String {
        var lines: [String] = []
        if hasLiveSession { lines.append("• su terminal sigue abierta y se cerrará") }
        lines += guards.map { "• " + $0.message }
        if lines.isEmpty { return "Se borra la carpeta del worktree. La rama se conserva." }
        return "Atención:\n" + lines.joined(separator: "\n")
            + "\n\nLa rama se conserva" + (guards.isEmpty ? "." : ", pero los cambios sin commitear se pierden.")
    }
}

private struct OfficeHeader: View {
    let office: Office
    let onNewWorktree: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(office.lighting == .off ? Color.secondary : Color.yellow)
            Text(office.project.name)
            Spacer()
            Text("\(office.worktrees.count)").foregroundStyle(.secondary)
            Button("Nuevo worktree", systemImage: "plus.circle", action: onNewWorktree)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private var icon: String {
        switch office.lighting {
        case .off: "lightbulb"
        case .singleDesk: "lightbulb.fill"
        case .allOn: "lightbulb.2.fill"
        }
    }
}

/// Terminal and review for one worktree. The terminal stays mounted while reviewing so it keeps its state.
private struct WorktreeDetail: View {
    let worktree: Worktree
    let project: Project
    // BULLPEN_SNAPSHOT_TAB=changes opens the review tab (for DebugSnapshots).
    @State private var tab = ProcessInfo.processInfo.environment["BULLPEN_SNAPSHOT_TAB"] == "changes" ? Tab.changes : .terminal
    @Environment(ReviewNotes.self) private var notes

    enum Tab: Hashable { case terminal, changes }

    var body: some View {
        ZStack {
            TerminalPane(worktree: worktree, environment: (try? WorktreeEnvironment.load(project: project, worktree: worktree))?.environment ?? [:])
                .opacity(tab == .terminal ? 1 : 0)
                .allowsHitTesting(tab == .terminal)
            if tab == .changes {
                ReviewView(worktree: worktree, project: project)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vista", selection: $tab) {
                    Text("Terminal").tag(Tab.terminal)
                    Text(changesLabel).tag(Tab.changes)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private var changesLabel: String {
        let count = notes.comments[worktree.id]?.count ?? 0
        return count > 0 ? "Cambios (\(count))" : "Cambios"
    }
}
