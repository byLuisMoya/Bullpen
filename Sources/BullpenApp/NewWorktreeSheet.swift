import BPAgents
import BPCore
import BPEnv
import BPGit
import BPIntegrations
import BPWorkspace
import SwiftUI

/// Creates a worktree and, optionally, starts an agent in it with the composed initial prompt (PLAN §6.1, §6.5).
struct NewWorktreeSheet: View {
    let project: Project
    var onCreated: (Worktree) -> Void
    @Environment(BuildingStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @AppStorage("globalInitialPrompt") private var globalPrompt = ""
    @AppStorage("lastAgent") private var agentID = AgentProfile.claude.id
    @State private var branch = ""
    @State private var baseRef = ""
    @State private var model = ""
    @State private var task = ""
    @State private var sendInitialPrompt = true
    @State private var isCreating = false
    @State private var installed: [String: Bool] = [:]
    @State private var config: Result<BullpenConfig, Error> = .success(BullpenConfig())
    @State private var suggesting = false
    @State private var compare = false
    @State private var overrideLimits = false
    @State private var ticket: Ticket?
    @State private var pickingTicket = false
    @Environment(AttentionCenter.self) private var attention
    @Environment(UsageCenter.self) private var usage
    @State private var variants: [VariantRow] = [VariantRow(agentID: AgentProfile.claude.id), VariantRow(agentID: AgentProfile.codex.id)]

    private var profile: AgentProfile? { AgentProfile.named(agentID) }
    private var path: String { WorktreeLocation.path(project: project.name, branch: branch).path }

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
        Form {
            Section {
                HStack {
                    if let ticket {
                        Label("\(ticket.key) · \(ticket.title)", systemImage: "ticket").lineLimit(1)
                        Button("Quitar") { self.ticket = nil }.buttonStyle(.borderless)
                    } else {
                        Text("Empieza desde un issue de GitHub o un ticket de Linear").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Desde ticket…") { pickingTicket = true }
                }
            }
            Section("Worktree en \(project.name)") {
                HStack {
                    TextField("Rama", text: $branch, prompt: Text("fix/login-timeout"))
                    Button(suggesting ? "Sugiriendo…" : "Sugerir") { Task { await suggestBranch() } }
                        .disabled(task.nilIfBlank == nil || suggesting)
                        .help("Propone un nombre a partir de la tarea con el modelo de tareas rápidas")
                }
                TextField("Base", text: $baseRef, prompt: Text("main"))
                if !branch.isEmpty {
                    LabeledContent("Carpeta") {
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            ConfigSummary(config: config)
            if let warning = limitWarning {
                Section {
                    Label(warning, systemImage: "gauge.with.dots.needle.100percent").foregroundStyle(.orange)
                    Toggle("Crear igualmente", isOn: $overrideLimits)
                }
            }
            Section {
                Toggle("Comparar varios agentes con la misma tarea", isOn: $compare)
                if compare {
                    ForEach($variants) { $row in
                        HStack {
                            Picker("Agente", selection: $row.agentID) {
                                ForEach(AgentProfile.all) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Modelo", text: $row.model, prompt: Text("por defecto"))
                            Button {
                                variants.removeAll { $0.id == row.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(variants.count <= 2)
                        }
                    }
                    Button("Añadir agente", systemImage: "plus") { variants.append(VariantRow(agentID: AgentProfile.claude.id)) }
                        .disabled(variants.count >= 5)
                    Text("Ramas: " + Workspace.branchNames(base: branch.isEmpty ? "rama" : branch, variants: workspaceVariants).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Agente") {
                Picker("Agente", selection: $agentID) {
                    ForEach(AgentProfile.all) { profile in
                        Text(installed[profile.id] == false ? "\(profile.name) (no encontrado)" : profile.name)
                            .tag(profile.id)
                    }
                    Text("Solo terminal").tag("")
                }
                if let profile {
                    HStack {
                        TextField("Modelo", text: $model, prompt: Text("por defecto"))
                        if !profile.models.isEmpty {
                            Menu("Sugerencias") {
                                ForEach(profile.models, id: \.self) { m in Button(m) { model = m } }
                            }
                            .fixedSize()
                        }
                    }
                    if installed[profile.id] == false {
                        Label("No se encuentra `\(profile.executable)` en tu PATH.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if profile != nil {
                Section("Tarea") {
                    TextEditor(text: $task)
                        .font(.body)
                        .frame(minHeight: 70)
                    Toggle("Incluir prompt inicial (global, del repo y del proyecto)", isOn: $sendInitialPrompt)
                    switch composed {
                    case let .success(prompt?):
                        DisclosureGroup("Prompt que se enviará") {
                            ScrollView {
                                Text(prompt)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 160)
                        }
                    case .success(nil):
                        Text("Se abrirá el agente sin prompt.").foregroundStyle(.secondary)
                    case let .failure(error):
                        Label(error.localizedDescription, systemImage: "xmark.octagon").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crear") { Task { await create() } }
                    .disabled(branch.isEmpty || baseRef.isEmpty || isCreating || isPromptInvalid || isConfigInvalid
                              || (compare && task.nilIfBlank == nil) || (limitWarning != nil && !overrideLimits))
            }
        }
        .sheet(isPresented: $pickingTicket) {
            TicketPicker(project: project) { picked in
                ticket = picked
                branch = picked.suggestedBranch
                task = Tickets.task(for: picked, project: project)
            }
        }
        .onAppear {
            baseRef = project.defaultBaseRef ?? "main"
            config = Result { try BullpenConfig.load(from: URL(fileURLWithPath: project.path)) }
        }
        .task { await detectInstalledAgents() }
    }

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

    /// Looks the agents up in the login shell's PATH (a Finder-launched app has a minimal PATH).
    private func detectInstalledAgents() async {
        for profile in AgentProfile.all {
            let found = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                process.arguments = ["-l", "-c", "command -v \(shellQuote(profile.executable))"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }.value
            installed[profile.id] = found
        }
    }
}

/// What `.bullpen.toml` will do for the new worktree.
private struct ConfigSummary: View {
    let config: Result<BullpenConfig, Error>

    var body: some View {
        switch config {
        case let .failure(error):
            Section(".bullpen.toml") {
                Label(error.localizedDescription, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        case let .success(config) where !config.isEmpty:
            Section(".bullpen.toml") {
                if !config.copy.isEmpty { LabeledContent("Copia", value: config.copy.joined(separator: ", ")) }
                if !config.clone.isEmpty { LabeledContent("Clona (APFS)", value: config.clone.joined(separator: ", ")) }
                if !config.setup.isEmpty { LabeledContent("Prepara", value: config.setup.joined(separator: " && ")) }
                if !config.portNames.isEmpty { LabeledContent("Puertos propios", value: config.portNames.joined(separator: ", ")) }
                if !config.env.isEmpty { LabeledContent("Variables", value: config.env.keys.sorted().joined(separator: ", ")) }
            }
        default:
            EmptyView()
        }
    }
}

struct VariantRow: Identifiable {
    let id = UUID()
    var agentID: String
    var model = ""
}
