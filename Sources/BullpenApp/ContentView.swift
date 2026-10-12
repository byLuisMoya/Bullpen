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
    @State private var demoBusy = false
    @AppStorage(BuildingName.key) private var buildingName = BuildingName.standard
    @Environment(\.openWindow) private var openWindow
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
        NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
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
                                    Button("Abrir en Terminal") { AppActions.openInTerminal(worktree) }
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
                                Button("Mostrar en Finder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: office.project.path)
                                }
                                Divider()
                                Button("Quitar proyecto", role: .destructive) { store.removeProject(office.project) }
                                    .disabled(!office.worktrees.isEmpty)
                                    .help(office.worktrees.isEmpty ? "Deja de mostrarlo (no borra nada del disco)" : "Elimina antes sus worktrees")
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            if let (worktree, project) = selectedWorktree {
                WorktreeDetail(worktree: worktree, project: project)
                    .id(worktree.id)
                    .navigationTitle(worktree.branch)
                    .navigationSubtitle(worktree.path)
            } else if store.offices.isEmpty {
                ContentUnavailableView {
                    Label("Aún no hay proyectos", systemImage: "building.2")
                } description: {
                    Text(AppActions.demoAvailable
                         ? "Añade un repositorio git para abrir su oficina, o prueba Bullpen con una demo (agentes simulados, no gasta tokens)."
                         : "Añade un repositorio git para abrir su oficina.")
                } actions: {
                    Button("Añadir proyecto…") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                    if AppActions.demoAvailable {
                        Button(demoBusy ? "Preparando…" : "Probar con una demo") { Task { await demo("start") } }
                            .disabled(demoBusy)
                    }
                }
            } else {
                BuildingView { selection = $0 }
                    .navigationTitle(buildingName.isEmpty ? BuildingName.standard : buildingName)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(buildingName.isEmpty ? BuildingName.standard : buildingName, systemImage: "building.2") { selection = nil }
                    .help("Ver todas las oficinas (⌘0)")
                    .keyboardShortcut("0", modifiers: .command)
                Button("Uso", systemImage: "chart.bar") { openWindow(id: "usage") }
                    .help("Uso y coste (⌘⇧U)")
                Button("Añadir proyecto", systemImage: "plus") { isImporting = true }
                    .help("Añadir un repositorio git")
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

    private func demo(_ action: String) async {
        demoBusy = true
        defer { demoBusy = false }
        do { try await AppActions.demo(action) } catch { store.errorMessage = error.localizedDescription }
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
    @Environment(SessionManager.self) private var sessions
    @Environment(BuildingStore.self) private var store
    @State private var tab: Tab = switch ProcessInfo.processInfo.environment["BULLPEN_SNAPSHOT_TAB"] {
    case "changes": .changes
    case "compare": .compare
    case "log": .log
    case "files": .files
    default: .terminal
    }
    @Environment(ReviewNotes.self) private var notes

    enum Tab: Hashable { case terminal, changes, files, compare, log }

    var body: some View {
        ZStack {
            TerminalPane(worktree: worktree, environment: (try? WorktreeEnvironment.load(project: project, worktree: worktree))?.environment ?? [:])
                .opacity(tab == .terminal ? 1 : 0)
                .allowsHitTesting(tab == .terminal)
            if tab == .changes {
                ReviewView(worktree: worktree, project: project)
            }
            if tab == .files {
                FilesView(worktree: worktree, project: project).background(Color(nsColor: .windowBackgroundColor))
            }
            if tab == .log {
                SessionLogView(worktree: worktree).background(Color(nsColor: .windowBackgroundColor))
            }
            if tab == .compare, let runID = worktree.runID {
                RunCompareView(runID: runID, project: project)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vista", selection: $tab) {
                    Text("Terminal").tag(Tab.terminal)
                    Text(changesLabel).tag(Tab.changes)
                    Text("Ficheros").tag(Tab.files)
                    Text("Bitácora").tag(Tab.log)
                    if worktree.runID != nil { Text("Comparar").tag(Tab.compare) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                Menu {
                    Button("Interrumpir (Ctrl-C)") { sessions.interrupt(worktree) }
                    Button(worktree.agentProfileID == nil ? "Reabrir terminal" : "Reiniciar agente") {
                        Task {
                            do {
                                let env = (try? WorktreeEnvironment.load(project: project, worktree: worktree))?.environment ?? [:]
                                try await sessions.restartAgent(worktree, environment: env)
                                tab = .terminal
                            } catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    Divider()
                    Button("Abrir en Terminal") { AppActions.openInTerminal(worktree) }
                    Button("Mostrar en Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path) }
                } label: {
                    Label("Agente", systemImage: "person.crop.circle.badge.gearshape")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help("Interrumpir o reiniciar el agente, abrir el worktree en Terminal o Finder")
            }
        }
    }

    private var changesLabel: String {
        let count = notes.comments[worktree.id]?.count ?? 0
        return count > 0 ? "Cambios (\(count))" : "Cambios"
    }
}
