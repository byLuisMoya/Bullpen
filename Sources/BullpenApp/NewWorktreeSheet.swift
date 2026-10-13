import BPAgents
import BPCore
import BPEnv
import BPGit
import BPIntegrations
import BPSessions
import BPWorkspace
import SwiftUI

/// Creates a worktree and, optionally, starts an agent in it with the composed initial prompt (PLAN §6.1, §6.5).
/// Laid out like Orca's: "Crear desde" with source tabs (smart search, GitHub, Linear, an existing
/// branch or just a name), the agent, and the task. Model, comparisons, the prompt preview and the
/// project's setup script live in the "Avanzado" tab.
struct NewWorktreeSheet: View {
    @State var project: Project
    var onCreated: (Worktree) -> Void
    @Environment(BuildingStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @AppStorage("globalInitialPrompt") private var globalPrompt = ""

    enum Pane: Hashable { case create, advanced }
    @State private var pane = Pane.create

    @State private var source = SourceTab.smart
    @State private var query = ""
    @State private var origin: Origin?
    @State private var tickets: [Ticket] = []
    @State private var ticketProblems: [String] = []
    @State private var loadingTickets = true
    @State private var pullRequests: [OpenPullRequest] = []
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []

    @State private var agentID = PrimaryAgent.id
    @State private var branch = ""
    /// Once the user types a branch name, the source and task stop renaming it.
    @State private var branchEdited = false
    @State private var baseRef = ""
    @State private var editingBase = false
    @State private var baseEdited = false
    @State private var model = ""
    @State private var task = ""
    @State private var setupScript = ""
    @State private var sendInitialPrompt = true
    @State private var isCreating = false
    @State private var installed: [String: Bool] = [:]
    @State private var config: Result<BullpenConfig, Error> = .success(BullpenConfig())
    @State private var suggesting = false
    @State private var compare = false
    @State private var overrideLimits = false
    @FocusState private var queryFocused: Bool
    @Environment(AttentionCenter.self) private var attention
    @Environment(UsageCenter.self) private var usage
    /// Comparing agents starts with the main one and another one.
    @State private var variants: [VariantRow] = {
        let main = PrimaryAgent.id
        let other = main == AgentProfile.codex.id ? AgentProfile.claude.id : AgentProfile.codex.id
        return [VariantRow(agentID: main), VariantRow(agentID: other)]
    }()

    private var profile: AgentProfile? { AgentProfile.named(agentID) }
    private var path: String { WorktreeLocation.path(project: project.name, branch: branch).path }
    private var ticket: Ticket? { if case let .ticket(t) = origin { t } else { nil } }

    private var request: WorktreeRequest {
        var request = WorktreeRequest(project: project, branch: branch, baseRef: baseRef, agent: profile, model: model,
                                      task: task, globalPrompt: globalPrompt, sendInitialPrompt: sendInitialPrompt)
        request.ticket = ticket?.ref
        return request
    }

    private var composed: Result<String?, Error> {
        Result { try Workspace.composePrompt(request, config: (try? config.get()) ?? BullpenConfig(), path: path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nuevo worktree").font(.title3.bold())
                Text(project.name).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 12)
                Picker("", selection: $pane) {
                    Text("Crear").tag(Pane.create)
                    Text("Avanzado").tag(Pane.advanced)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            Group {
                switch pane {
                case .create: createPane
                case .advanced: advancedPane
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if let problem { Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout) }
            if let profile, installed[profile.id] == false, !compare {
                Label("No se encuentra `\(profile.executable)` en tu PATH.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            if let warning = limitWarning {
                HStack {
                    Label(warning, systemImage: "gauge.with.dots.needle.100percent").foregroundStyle(.orange)
                    Spacer()
                    Toggle("Crear igualmente", isOn: $overrideLimits).toggleStyle(.checkbox)
                }
                .font(.callout)
            }

            HStack {
                if !branch.isEmpty {
                    Text(path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head).help(path)
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text(compare ? "Crear \(variants.count) worktrees" : "Crear") }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .help("⌘↩")
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            baseRef = project.defaultBaseRef ?? "main"
            setupScript = project.setupScript ?? ""
            config = Result { try BullpenConfig.load(from: URL(fileURLWithPath: project.path)) }
            queryFocused = true
        }
        .onChange(of: task) { _, value in
            if origin == nil, !branchEdited { branch = WorktreeSource.branchName(from: value) }
        }
        .onChange(of: query) { _, _ in pickFirstCandidate() }
        .onChange(of: source) { _, _ in pickFirstCandidate() }
        .task { await detectInstalledAgents() }
        .task { await loadBranches() }
        .task {
            (tickets, ticketProblems) = await Tickets.load(project: project)
            loadingTickets = false
            pickFirstCandidate()
        }
        // The setup script is the project's: saved as you type, used by every new worktree.
        .task(id: setupScript) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, setupScript.nilIfBlank != project.setupScript?.nilIfBlank else { return }
            project.setupScript = setupScript.nilIfBlank
            store.updateProject(project)
        }
    }

    // MARK: Crear

    private var createPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Crear desde").font(.callout)
                    Text("[Opcional]").font(.callout).foregroundStyle(.tertiary)
                    Spacer()
                    baseChip
                }
                SourceTabs(selection: $source)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("", text: $query, prompt: Text(source.placeholder))
                        .textFieldStyle(.plain)
                        .focused($queryFocused)
                        .onSubmit { pickFirstCandidate() }
                    if !query.isEmpty {
                        Button { query = ""; origin = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                candidatesList
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    TextField("Rama", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }),
                              prompt: Text("nombre de la rama (sale de la tarea si lo dejas vacío)"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExistingBranch)
                    Button {
                        Task { await suggestBranch() }
                    } label: {
                        if suggesting { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(task.nilIfBlank == nil || suggesting || isExistingBranch)
                    .help("Proponer un nombre con el modelo de tareas rápidas")
                }
                if isExistingBranch {
                    Text("Se abre la rama existente en un worktree nuevo.").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Agente").font(.callout)
                    Spacer()
                    Button { pane = .advanced } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .help("Modelo, varios agentes y prompt (Avanzado)")
                }
                Picker("Agente", selection: $agentID) {
                    ForEach(AgentProfile.all) { p in
                        Text(installed[p.id] == false ? "\(p.name) (no encontrado)" : p.name).tag(p.id)
                    }
                    Divider()
                    Text("Solo terminal").tag("")
                }
                .labelsHidden()
                .disabled(compare)
                if compare {
                    Text("Comparando \(variants.count) agentes (Avanzado).").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(profile == nil && !compare ? "Notas" : "Tarea").font(.callout)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $task)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                    if task.isEmpty {
                        Text(profile == nil && !compare ? "Notas para este worktree (opcional)" : "¿Qué tiene que hacer el agente? (opcional)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 90)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private var baseChip: some View {
        Button {
            editingBase = true
        } label: {
            Label(baseRef.isEmpty ? "base" : baseRef, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: 180)
        .help("Rama o commit de la que parte el worktree")
        .popover(isPresented: $editingBase, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Base", text: Binding(get: { baseRef }, set: { baseRef = $0; baseEdited = true }), prompt: Text("main"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editingBase = false }
                ForEach(localBranches.prefix(8), id: \.self) { b in
                    Button {
                        baseRef = b
                        baseEdited = true
                        editingBase = false
                    } label: {
                        HStack {
                            Text(b).lineLimit(1)
                            Spacer()
                            if b == baseRef { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                if project.defaultBaseRef == baseRef {
                    Label("Base por defecto de \(project.name)", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Usar siempre «\(baseRef)» en \(project.name)") {
                        project.defaultBaseRef = baseRef.nilIfBlank
                        store.updateProject(project)
                    }
                    .disabled(baseRef.nilIfBlank == nil)
                    .font(.caption)
                }
            }
            .frame(width: 240)
            .padding(12)
        }
    }

    // MARK: Sources

    enum SourceTab: CaseIterable, Hashable {
        case smart, github, linear, branch, name

        var title: String {
            switch self {
            case .smart: "Inteligente"
            case .github: "GitHub"
            case .linear: "Linear"
            case .branch: "Rama"
            case .name: "Nombre"
            }
        }

        var icon: String {
            switch self {
            case .smart: "sparkles"
            case .github: "number"
            case .linear: "circle.lefthalf.striped.horizontal"
            case .branch: "arrow.triangle.branch"
            case .name: "textformat"
            }
        }

        var placeholder: String {
            switch self {
            case .smart: "Escribe un nombre, #1234, una rama o una URL de GitHub o Linear"
            case .github: "Busca un issue por número o título"
            case .linear: "Busca un ticket de Linear (ABC-123 o título)"
            case .branch: "Busca una rama existente"
            case .name: "Nombre de la rama nueva"
            }
        }
    }

    enum Origin: Hashable {
        case ticket(Ticket)
        /// An open PR: its branch, checked out (fetched first if it was never pulled).
        case pullRequest(OpenPullRequest)
        case branch(String)
        /// `origin/x`: a local `x` is created from it.
        case remote(String)
        case name(String)
    }

    private var isExistingBranch: Bool {
        switch origin {
        case .branch, .pullRequest: true
        default: false
        }
    }

    /// What the search field matches in the current tab, best match first.
    private var candidates: [Origin] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func ticketsMatching(_ source: Ticket.Source?) -> [Origin] {
            let pool = tickets.filter { source == nil || $0.source == source }
            guard !q.isEmpty else { return source == nil ? [] : pool.prefix(6).map { .ticket($0) } }
            if let key = WorktreeSource.ticketKey(in: q) {
                return pool.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map { .ticket($0) }
            }
            return pool.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.key.localizedCaseInsensitiveContains(q) }
                .prefix(6).map { .ticket($0) }
        }
        func pullRequestsMatching() -> [Origin] {
            guard !q.isEmpty else { return pullRequests.prefix(6).map { .pullRequest($0) } }
            if let key = WorktreeSource.ticketKey(in: q) {
                return pullRequests.filter { "#\($0.number)" == key }.map { .pullRequest($0) }
            }
            return pullRequests.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.branch.localizedCaseInsensitiveContains(q) }
                .prefix(6).map { .pullRequest($0) }
        }
        func branchesMatching(limit: Int) -> [Origin] {
            let local = localBranches.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }.map { Origin.branch($0) }
            let remote = remoteBranches
                .filter { r in (q.isEmpty || r.localizedCaseInsensitiveContains(q)) && !localBranches.contains(WorktreeSource.localName(r)) }
                .map { Origin.remote($0) }
            return Array((local + remote).prefix(limit))
        }
        switch source {
        case .smart:
            guard !q.isEmpty else { return [] }
            let exact = localBranches.contains(q) ? [Origin.branch(q)] : []
            var result = ticketsMatching(nil).prefix(3) + (q.count > 1 || WorktreeSource.ticketKey(in: q) != nil ? pullRequestsMatching().prefix(3) : []) + exact
            if WorktreeSource.ticketKey(in: q) == nil {
                result += branchesMatching(limit: 3).filter { !exact.contains($0) }
                if exact.isEmpty { result.append(.name(q)) }
            }
            return Array(result)
        case .github: return pullRequestsMatching() + ticketsMatching(.github)
        case .linear: return ticketsMatching(.linear)
        case .branch: return branchesMatching(limit: 8)
        case .name: return q.isEmpty ? [] : [.name(q)]
        }
    }

    @ViewBuilder private var candidatesList: some View {
        let rows = candidates
        let waiting = loadingTickets && [.github, .linear, .smart].contains(source)
        if !rows.isEmpty || waiting || !hint.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.self) { row in
                    Button {
                        select(row)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: row)).frame(width: 16).foregroundStyle(.secondary)
                            Text(title(for: row)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            if origin == row { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(origin == row ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if waiting && rows.isEmpty {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Cargando tickets…") }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                if !hint.isEmpty {
                    Text(hint).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }
            .frame(maxHeight: 180)
        }
    }

    /// Why a tab shows nothing.
    private var hint: String {
        guard !loadingTickets else { return "" }
        switch source {
        case .github where !tickets.contains { $0.source == .github } && pullRequests.isEmpty:
            return ticketProblems.first { $0.hasPrefix("GitHub") }
                ?? (GitHubCLI.locate() == nil ? "Instala gh y ejecuta gh auth login para ver issues y PR." : "No hay issues ni PR abiertas.")
        case .linear where Tickets.linearKey == nil:
            return "Añade tu clave de Linear en Ajustes › Integraciones."
        case .linear where !tickets.contains { $0.source == .linear }:
            return ticketProblems.first { !$0.hasPrefix("GitHub") } ?? "No tienes tickets abiertos en Linear."
        case .smart where WorktreeSource.ticketKey(in: query) != nil && candidates.isEmpty:
            return "No está entre los tickets abiertos."
        default:
            return ""
        }
    }

    private func icon(for origin: Origin) -> String {
        switch origin {
        case let .ticket(t): t.source == .github ? SourceTab.github.icon : SourceTab.linear.icon
        case .pullRequest: "arrow.triangle.pull"
        case .branch, .remote: SourceTab.branch.icon
        case .name: "plus"
        }
    }

    private func title(for origin: Origin) -> String {
        switch origin {
        case let .ticket(t): "\(t.key) · \(t.title)"
        case let .pullRequest(pr): "PR #\(pr.number)\(pr.isDraft ? " (borrador)" : "") · \(pr.title)"
        case let .branch(b): b
        case let .remote(r): r
        case let .name(n): "Rama nueva: \(WorktreeSource.branchName(fromName: n))"
        }
    }

    private func pickFirstCandidate() {
        if let first = candidates.first, source != .github, source != .linear, source != .branch {
            select(first)
        } else if candidates.isEmpty, case .name = origin {
            origin = nil
            if !branchEdited { branch = WorktreeSource.branchName(from: task) }
        }
    }

    private func select(_ new: Origin) {
        let previous = origin
        origin = new
        branchEdited = false
        switch new {
        case let .ticket(t):
            branch = t.suggestedBranch
            if previous != new { task = Tickets.task(for: t, project: project) }
        case let .pullRequest(pr):
            branch = pr.branch
            // Its own branch if it is already here; otherwise a local one from the remote's.
            if !localBranches.contains(pr.branch) { baseRef = "origin/\(pr.branch)" }
        case let .branch(b):
            branch = b
        case let .remote(r):
            branch = WorktreeSource.localName(r)
            baseRef = r
        case let .name(n):
            branch = WorktreeSource.branchName(fromName: n)
        }
        if case let .ticket(old)? = previous, previous != new, task == Tickets.task(for: old, project: project) {
            task = ""
        }
    }

    private func loadBranches() async {
        guard let repo = try? await Repository.open(at: URL(fileURLWithPath: project.path)) else { return }
        localBranches = (try? await repo.localBranches()) ?? []
        remoteBranches = (try? await repo.remoteBranches()) ?? []
        // No base saved for the project: start from the remote's default branch.
        if project.defaultBaseRef == nil, !baseEdited, let main = await repo.defaultRemoteBranch() { baseRef = main }
        if let gh = GitHubCLI.locate() {
            pullRequests = (try? await gh.openPullRequests(in: URL(fileURLWithPath: project.path))) ?? []
            pickFirstCandidate()
        }
    }

    // MARK: Avanzado

    private var advancedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Script de preparación").font(.callout.bold())
                    Text("Se ejecuta en cada worktree nuevo de \(project.name), antes de abrir el agente. Se guarda solo, para todos los que crees a partir de ahora.")
                        .font(.caption).foregroundStyle(.secondary)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $setupScript)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                        if setupScript.isEmpty {
                            Text("pnpm install\ncp \"$BULLPEN_PROJECT_PATH/.env\" .env")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 110)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                    Text("Se detiene en la primera línea que falle; entonces no se abre el agente y te quedas en la terminal del worktree.")
                        .font(.caption).foregroundStyle(.secondary)
                    ConfigSummary(config: config)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if let profile, !compare {
                        HStack {
                            Text("Modelo")
                            TextField("Modelo", text: $model, prompt: Text("por defecto"))
                                .textFieldStyle(.roundedBorder)
                            if !profile.models.isEmpty {
                                Menu("Sugerencias") {
                                    Button("Por defecto") { model = "" }
                                    Divider()
                                    ForEach(profile.models, id: \.self) { m in Button(m) { model = m } }
                                }
                                .frame(width: 120)
                            }
                        }
                    }
                    if profile != nil || compare {
                        Toggle("Incluir el prompt inicial (global, del repo y del proyecto)", isOn: $sendInitialPrompt)
                    }
                    Toggle("Comparar varios agentes con la misma tarea", isOn: $compare)
                    if compare {
                        ForEach($variants) { $row in
                            HStack {
                                Picker("Agente", selection: $row.agentID) {
                                    ForEach(AgentProfile.all) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden()
                                .frame(width: 170)
                                TextField("Modelo", text: $row.model, prompt: Text("por defecto")).textFieldStyle(.roundedBorder)
                                Button {
                                    variants.removeAll { $0.id == row.id }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .disabled(variants.count <= 2)
                            }
                        }
                        HStack {
                            Button("Añadir agente", systemImage: "plus") { variants.append(VariantRow(agentID: PrimaryAgent.id)) }
                                .disabled(variants.count >= 5)
                            Spacer()
                            Text("Ramas: " + Workspace.branchNames(base: branch.isEmpty ? "rama" : branch, variants: workspaceVariants).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if profile != nil || compare, case let .success(prompt?) = composed {
                        DisclosureGroup("Prompt que se enviará") {
                            ScrollView {
                                Text(prompt)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 420)
    }

    /// Something that blocks creating, said in one line.
    private var problem: String? {
        if case let .failure(error) = config { return ".bullpen.toml: \(error.localizedDescription)" }
        if profile != nil || compare, case let .failure(error) = composed { return error.localizedDescription }
        if compare && task.nilIfBlank == nil { return "Para comparar agentes, escribe la tarea." }
        return nil
    }

    private var canCreate: Bool {
        !branch.isEmpty && !baseRef.isEmpty && !isCreating && !isPromptInvalid && !isConfigInvalid
            && !(compare && task.nilIfBlank == nil) && (limitWarning == nil || overrideLimits)
    }


}

/// Underlined tabs for where the worktree comes from.
private struct SourceTabs: View {
    @Binding var selection: NewWorktreeSheet.SourceTab

    var body: some View {
        HStack(spacing: 18) {
            ForEach(NewWorktreeSheet.SourceTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 6) {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.callout.weight(selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? .primary : .secondary)
                        Rectangle()
                            .fill(selection == tab ? Color.primary : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }
}

extension NewWorktreeSheet {
    /// Max agents at once and daily budget from Settings › Límites.
    private var limitWarning: String? {
        let newAgents = profile == nil ? 0 : (compare ? variants.count : 1)
        guard newAgents > 0 else { return nil }
        // Agents still alive: worktrees with an agent whose status isn't "stopped".
        let running = store.offices.flatMap(\.worktrees)
            .filter { $0.agentProfileID != nil && attention.statuses[$0.id]?.state != .dead }
            .count
        if Limits.maxAgents > 0, running + newAgents > Limits.maxAgents {
            return "Superarías el límite de \(Limits.maxAgents) agentes a la vez (hay \(running))."
        }
        if Limits.dailyBudget > 0, usage.today.costUSD >= Limits.dailyBudget {
            return "Hoy ya se ha alcanzado el presupuesto diario (\(UsageWindow.money(usage.today.costUSD)))."
        }
        return nil
    }

    private var isConfigInvalid: Bool {
        if case .failure = config { return true }
        return false
    }

    private var isPromptInvalid: Bool {
        guard profile != nil, case .failure = composed else { return false }
        return true
    }

    private func suggestBranch() async {
        guard let task = task.nilIfBlank else { return }
        suggesting = true
        defer { suggesting = false }
        do {
            branch = try await ModelService.suggestBranchName(for: task, project: project.name)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private var workspaceVariants: [Workspace.Variant] {
        variants.compactMap { row in AgentProfile.named(row.agentID).map { Workspace.Variant(agent: $0, model: row.model.nilIfBlank) } }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        // A PR branch that was never pulled: fetch it so origin/<branch> exists to start from.
        if case let .pullRequest(pr) = origin, !localBranches.contains(pr.branch),
           let repo = try? await Repository.open(at: URL(fileURLWithPath: project.path)) {
            do { try await repo.fetchBranch(pr.branch) } catch {
                store.errorMessage = "No se pudo traer la rama de la PR #\(pr.number): \(error.localizedDescription)"
                return
            }
        }
        if compare {
            guard let worktrees = await store.createRun(request, variants: workspaceVariants), let first = worktrees.first else { return }
            onCreated(first)
        } else {
            guard let worktree = await store.createWorktree(request) else { return }
            onCreated(worktree)
        }
        if let ref = ticket?.ref {
            do { try await Tickets.started(ref) } catch {
                store.errorMessage = "Worktree creado, pero no se pudo mover \(ref.key) en Linear: \(error.localizedDescription)"
            }
        }
        dismiss()
    }

    /// Looks the agents up in the PATH of the user's terminal (a Finder-launched app has a
    /// minimal PATH, and a non-interactive shell misses what ~/.zshrc adds).
    private func detectInstalledAgents() async {
        let profiles = AgentProfile.all
        let found = await Task.detached {
            Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, ShellEnvironment.locate($0.executable) != nil) })
        }.value
        installed = found
    }
}

/// What `.bullpen.toml` will do for the new worktree.
private struct ConfigSummary: View {
    let config: Result<BullpenConfig, Error>

    var body: some View {
        if case let .success(config) = config, !config.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(".bullpen.toml").font(.caption.bold()).foregroundStyle(.secondary)
                Group {
                    if !config.copy.isEmpty { LabeledContent("Copia", value: config.copy.joined(separator: ", ")) }
                    if !config.clone.isEmpty { LabeledContent("Clona (APFS)", value: config.clone.joined(separator: ", ")) }
                    if !config.setup.isEmpty { LabeledContent("Prepara", value: config.setup.joined(separator: " && ")) }
                    if !config.portNames.isEmpty { LabeledContent("Puertos propios", value: config.portNames.joined(separator: ", ")) }
                    if !config.env.isEmpty { LabeledContent("Variables", value: config.env.keys.sorted().joined(separator: ", ")) }
                }
                .font(.caption)
            }
        }
    }
}

struct VariantRow: Identifiable {
    let id = UUID()
    var agentID: String
    var model = ""
}
