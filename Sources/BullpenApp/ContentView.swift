import BPAgents
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
    @Environment(SummaryCenter.self) private var summaries
    /// Projects folded in the sidebar (only the header shows), remembered between launches.
    @AppStorage("collapsedProjects") private var collapsedRaw = ""
    private var collapsedProjects: Set<UUID> {
        get { Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }
        nonmutating set { collapsedRaw = newValue.map(\.uuidString).sorted().joined(separator: ",") }
    }
    @State private var pendingRemoval: PendingRemoval?

    private var selection: UUID? {
        get { navigation.selection }
        nonmutating set { navigation.selection = newValue }
    }

    var body: some View {
        @Bindable var store = store
        @Bindable var navigation = navigation
        // Our own sidebar column instead of NavigationSplitView: AppKit's split view finished the
        // expansion with a jump once the sidebar passed the window buttons, whatever the animation.
        HStack(spacing: 0) {
            SidebarColumn(visible: navigation.columnVisibility != .detailOnly, width: $sidebarWidth) {
            List(selection: $navigation.selection) {
                ForEach(store.offices) { office in
                    Section {
                        if !collapsedProjects.contains(office.project.id) {
                        MiniOffice(office: office, onSelect: { selection = $0 }, onOpen: { navigation.showOffice(office.project.id) })
                            .selectionDisabled()
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        ForEach(office.worktrees) { worktree in
                            WorktreeRow(
                                worktree: worktree, status: attention.statuses[worktree.id],
                                sync: repoStatus.branches[worktree.id], pullRequest: repoStatus.pullRequests[worktree.id],
                                warning: repoStatus.warnings[worktree.id], summary: summaries.summaries[worktree.id]
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
                        }
                    } header: {
                        OfficeHeader(office: office, collapsed: Binding(
                            get: { collapsedProjects.contains(office.project.id) },
                            set: { collapsed in
                                withAnimation(.snappy(duration: 0.2)) {
                                    if collapsed { collapsedProjects.insert(office.project.id) } else { collapsedProjects.remove(office.project.id) }
                                }
                            }
                        )) { newWorktreeFor = office.project }
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
                    // Our own chevron in the header, always visible; not the hover-only system one.
                    .collapsible(false)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .regular))
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Ajustes (⌘,)")
                    PlanUsageBadge()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                // A plain line: a Divider here takes the HStack's axis and draws vertically,
                // splitting the footer in two.
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
            }
            }
            Group {
            if let (worktree, project) = selectedWorktree {
                WorktreeDetail(worktree: worktree, project: project) { isImporting = true }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(Navigation.sidebarAnimation) { navigation.toggleSidebar() }
                } label: {
                    Label("Barra lateral", systemImage: "sidebar.left")
                }
                .help("Mostrar u ocultar la barra lateral (⌃⌘S)")
            }
            // With a worktree open, its toolbar carries these too, so they all line up on the right.
            if selectedWorktree == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Añadir proyecto", systemImage: "plus") { isImporting = true }
                        .help("Añadir un repositorio git")
                    Button("Uso", systemImage: "chart.bar") { openWindow(id: "usage") }
                        .help("Uso y coste (⌘⇧U)")
                    UpdateButton()
                }
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

    @AppStorage("sidebarWidth") private var sidebarWidth = 270.0

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
    @Binding var collapsed: Bool
    let onNewWorktree: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(office.lighting == .off ? Color.secondary : Color.yellow)
            Text(office.project.name)
            Spacer()
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(collapsed ? "Mostrar la oficina y sus worktrees" : "Ocultar la oficina y sus worktrees")
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

/// One worktree: its terminal fills the window; files, changes and the log open in a panel on
/// the right (toolbar button), so the terminal never leaves the screen.
private struct WorktreeDetail: View {
    let worktree: Worktree
    let project: Project
    var onAddProject: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(SessionManager.self) private var sessions
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention
    @State private var restarting = false
    // BULLPEN_SNAPSHOT_TAB=changes opens the panel on that tab (for DebugSnapshots).
    @AppStorage("worktreePanel.shown") private var panelShown = ProcessInfo.processInfo.environment["BULLPEN_SNAPSHOT_TAB"] != nil

    /// The worktree has an agent but it isn't running (it exited, or never started).
    private var agentStopped: Bool {
        worktree.agentProfileID != nil && attention.statuses[worktree.id]?.state == .dead
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if agentStopped {
                    HStack(spacing: 10) {
                        Label("\(AgentProfile.named(worktree.agentProfileID)?.name ?? "El agente") no está en ejecución",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(restarting ? "Reiniciando…" : "Reiniciar agente") { Task { await restartAgent() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(restarting)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
                }
                TerminalPane(worktree: worktree, environment: (try? WorktreeEnvironment.load(project: project, worktree: worktree))?.environment ?? [:])
            }
        }
        .inspector(isPresented: $panelShown) {
            WorktreePanel(worktree: worktree, project: project)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 900)
        }
        // Everything on the right, in one group so the order holds: agent, add project, usage, panel.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Interrumpir (Ctrl-C)") { sessions.interrupt(worktree) }
                    Button(worktree.agentProfileID == nil ? "Reabrir terminal" : "Reiniciar agente") {
                        Task { await restartAgent() }
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
                Button("Añadir proyecto", systemImage: "plus", action: onAddProject)
                    .help("Añadir un repositorio git")
                Button("Uso", systemImage: "chart.bar") { openWindow(id: "usage") }
                    .help("Uso y coste (⌘⇧U)")
                Button("Panel", systemImage: "sidebar.right") { withAnimation { panelShown.toggle() } }
                    .help(panelShown ? "Ocultar ficheros, cambios y bitácora" : "Ver ficheros, cambios y bitácora")
                UpdateButton()
            }
        }
    }

    private func restartAgent() async {
        restarting = true
        defer { restarting = false }
        do {
            let env = (try? WorktreeEnvironment.load(project: project, worktree: worktree))?.environment ?? [:]
            try await sessions.restartAgent(worktree, environment: env)
        } catch { store.errorMessage = error.localizedDescription }
    }

}

/// The sidebar: a column whose width SwiftUI animates between 0 and `width`. The content keeps
/// its full width and is clipped from the leading edge, so it slides in and out whole and never
/// re-lays out mid-animation. The divider can be dragged to resize (220–420 pt).
struct SidebarColumn<Content: View>: View {
    let visible: Bool
    @Binding var width: Double
    @ViewBuilder var content: Content
    @State private var dragStart: Double?

    static var range: ClosedRange<Double> { 220...420 }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(width: width)
                .background(SidebarMaterial())
                .frame(width: visible ? width : 0, alignment: .trailing)
                .clipped()
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: visible ? 1 : 0)
                .overlay {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    width = min(max(start + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                        .allowsHitTesting(visible)
                }
        }
    }
}

/// The translucent sidebar background macOS uses.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
