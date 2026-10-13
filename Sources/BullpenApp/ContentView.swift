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
    /// Kept in @State (animated transactions) and mirrored to the stored list.
    @State private var collapsedProjects: Set<UUID> = []
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
            // Our own column instead of a sidebar List: List doesn't animate rows appearing and
            // disappearing, and a project's office and worktrees must slide in and out smoothly.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                ForEach(store.offices) { office in
                        OfficeHeader(office: office, collapsed: Binding(
                            get: { collapsedProjects.contains(office.project.id) },
                            set: { collapsed in
                                withAnimation(.easeInOut(duration: 0.25)) {
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
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .zIndex(1)
                        VStack(alignment: .leading, spacing: 1) {
                        MiniOffice(office: office, onSelect: { selection = $0 }, onOpen: { navigation.showOffice(office.project.id) })
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        ForEach(office.worktrees) { worktree in
                            WorktreeRow(
                                worktree: worktree, status: attention.statuses[worktree.id],
                                sync: repoStatus.branches[worktree.id], pullRequest: repoStatus.pullRequests[worktree.id],
                                warning: repoStatus.warnings[worktree.id], summary: summaries.summaries[worktree.id]
                            )
                                .sidebarRow(selected: selection == worktree.id) { selection = worktree.id }
                                .contextMenu {
                                    Button("Mostrar en Finder") {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                                    }
                                    Button("Abrir en Terminal") { AppActions.openInTerminal(worktree) }
                                    if worktree.external {
                                        // Made in Orca or with git: only stop showing it here.
                                        Button("Quitar de Bullpen") {
                                            Task {
                                                if selection == worktree.id { selection = nil }
                                                await store.removeWorktree(worktree, in: office.project, force: false)
                                            }
                                        }
                                        .help("Deja de mostrarlo; la carpeta y la rama siguen donde estén (Orca, git)")
                                        Button(worktree.path.contains("/orca/") ? "Eliminar worktree (también en Orca)…" : "Eliminar worktree…",
                                               role: .destructive) {
                                            Task { await confirmRemoval(worktree, in: office.project) }
                                        }
                                    } else {
                                        Button("Eliminar worktree…", role: .destructive) {
                                            Task { await confirmRemoval(worktree, in: office.project) }
                                        }
                                    }
                                }
                        }
                        }
                        // Always there, folded to zero height: its height animates with the toggle.
                        .modifier(Fold(progress: collapsedProjects.contains(office.project.id) ? 0 : 1))
                }
                }
                .padding(.bottom, 8)
            }
            // Content sliding up while folding stays under the header and above nothing else.
            .clipped()
            .onAppear { collapsedProjects = Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }
            .onChange(of: collapsedProjects) { _, now in collapsedRaw = now.map(\.uuidString).sorted().joined(separator: ",") }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                if let outdated = sessions.outdatedDaemon {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("El servicio de terminales es de la versión \(outdated.build)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                        Text("No puede pasar sus \(outdated.running) terminal(es) a la versión nueva. Reinícialo cuando te venga bien: se cerrarán y los agentes se podrán reiniciar. Desde esta versión ya no hará falta.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Reiniciar ahora") { Task { await sessions.restartOutdatedDaemon() } }
                            .controlSize(.small)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                }
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
                    await store.removeWorktree(removal.worktree, in: removal.project, force: !removal.guards.isEmpty,
                                               deleteExternal: removal.worktree.external)
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
        if worktree.external, worktree.path.contains("/orca/") {
            lines.append("• se elimina también en Orca (y Orca borra su rama si ya está integrada)")
        }
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
    /// The terminal tab shown: nil is the agent's, otherwise an extra terminal's session id.
    @State private var terminalTab: String?
    // BULLPEN_SNAPSHOT_TAB=changes opens the panel on that tab (for DebugSnapshots).
    @AppStorage("worktreePanel.shown") private var panelShown = ProcessInfo.processInfo.environment["BULLPEN_SNAPSHOT_TAB"] != nil

    @Environment(OrcaCenter.self) private var orca
    @Environment(BrowserCenter.self) private var browsers

    /// A worktree from Orca whose agent lives there: here it gets a plain terminal.
    private var agentInOrca: OrcaActivity? {
        guard worktree.agentProfileID == nil, let activity = orca.activity(for: worktree), activity.liveTerminals > 0 else { return nil }
        return activity
    }

    /// The worktree has an agent but it isn't running (it exited, or never started).
    private var agentStopped: Bool {
        worktree.agentProfileID != nil && attention.statuses[worktree.id]?.state == .dead
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let inOrca = agentInOrca {
                    HStack(spacing: 10) {
                        Label("Su agente trabaja en Orca\(inOrca.agentState.map { " (\($0))" } ?? ""). Aquí tienes una terminal en su carpeta.",
                              systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Arrancar \(AgentProfile.named(PrimaryAgent.id)?.name ?? "el agente") aquí también") {
                            Task {
                                store.setAgent(PrimaryAgent.id, for: worktree)
                                var adopted = worktree
                                adopted.agentProfileID = PrimaryAgent.id
                                try? await sessions.restartAgent(adopted, environment: terminalEnvironment)
                            }
                        }
                        .controlSize(.small)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
                }
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
                TerminalTabs(worktree: worktree, selection: $terminalTab) { Task { await openTab() } }
                if terminalTab == TerminalTabs.browser, browsers.open.contains(worktree.id) {
                    BrowserPane(worktree: worktree, home: browserHome)
                } else {
                    TerminalPane(worktree: worktree, environment: terminalEnvironment, tab: terminalTab)
                        .id(terminalTab ?? "main")
                        .overlay(alignment: .bottomTrailing) {
                            DictationButton { text in
                                sessions.typeText(text, into: terminalTab ?? SessionManager.sessionID(for: worktree))
                            }
                        }
                }
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

    /// The worktree's own URL for its browser tab (`[browser] url`, or its preview port).
    private var browserHome: String {
        (try? store.workspace?.browserURL(for: worktree, in: project)) ?? "http://localhost:3000"
    }

    private var terminalEnvironment: [String: String] {
        (try? WorktreeEnvironment.load(project: project, worktree: worktree))?.environment ?? [:]
    }

    private func openTab() async {
        do { terminalTab = try await sessions.openTab(for: worktree, environment: terminalEnvironment) } catch {
            store.errorMessage = "No se pudo abrir otra terminal: \(error.localizedDescription)"
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

/// Tabs over the worktree's terminal: its agent first, then any extra terminals, and "+".
private struct TerminalTabs: View {
    /// The browser tab's id in `selection` (terminal tabs are session ids).
    static let browser = "browser"
    let worktree: Worktree
    @Binding var selection: String?
    var onAdd: () -> Void
    @Environment(SessionManager.self) private var sessions
    @Environment(OrcaCenter.self) private var orca
    @Environment(BrowserCenter.self) private var browsers

    /// What the first tab runs: the worktree's agent, the main agent for an Orca worktree, or a
    /// terminal (terminal-only, or Orca already has the agent).
    private var mainTitle: (String, String) {
        if let agent = AgentProfile.named(worktree.agentProfileID) { return (agent.name, "sparkles") }
        if worktree.external, (orca.activity(for: worktree)?.liveTerminals ?? 0) == 0 {
            return (AgentProfile.named(PrimaryAgent.id)?.name ?? "Agente", "sparkles")
        }
        return ("Terminal", "terminal")
    }

    var body: some View {
        let extra = sessions.tabs(for: worktree)
        HStack(spacing: 2) {
            tab(id: nil, title: mainTitle.0, icon: mainTitle.1, closable: false)
            // Only once an agent has used the browser (Bullpen's MCP tools) in this worktree.
            if browsers.open.contains(worktree.id) {
                tab(id: Self.browser, title: "Navegador", icon: "globe", closable: true)
            }
            ForEach(Array(extra.enumerated()), id: \.element) { index, id in
                tab(id: id, title: "Terminal \(index + 2)", icon: "terminal", closable: true)
            }
            Button(action: onAdd) {
                Image(systemName: "plus").frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Abrir otra terminal en este worktree")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(white: 0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        // A tab whose terminal was closed from inside (exit) falls back to the agent's.
        .onChange(of: extra) { _, now in
            if let selection, selection != Self.browser, !now.contains(selection) { self.selection = nil }
        }
        // A remembered browser tab that isn't open (any more) shows the agent instead.
        .onAppear { if selection == Self.browser, !browsers.open.contains(worktree.id) { selection = nil } }
    }

    private func tab(id: String?, title: String, icon: String, closable: Bool) -> some View {
        let selected = selection == id
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.callout).lineLimit(1)
            if closable, let id {
                Button {
                    if selection == id { selection = nil }
                    if id == Self.browser { browsers.close(worktree.id) } else { Task { await sessions.closeTab(id) } }
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Cerrar esta terminal")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
        .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selection = id }
    }
}

extension View {
    /// A selectable row of our sidebar column: the system's sidebar look (rounded highlight,
    /// hover tint) without a List.
    func sidebarRow(selected: Bool, onSelect: @escaping () -> Void) -> some View {
        modifier(SidebarRow(selected: selected, onSelect: onSelect))
    }
}

private struct SidebarRow: ViewModifier {
    let selected: Bool
    var onSelect: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .onTapGesture(perform: onSelect)
            .padding(.horizontal, 8)
    }
}

/// Folds its content to zero height (progress 0) and back (1), animating the height so what
/// follows slides along, and clipping what doesn't fit yet.
private struct Fold: ViewModifier, Animatable {
    var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(height: height.map { $0 * progress }, alignment: .top)
            .clipped()
            .opacity(Double(min(1, progress * 1.5)))
            .allowsHitTesting(progress > 0.5)
    }
}
