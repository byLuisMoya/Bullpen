import BPAgents
import BPCore
import BPEnv
import BPGit
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

    private var profile: AgentProfile? { AgentProfile.named(agentID) }
    private var path: String { WorktreeLocation.path(project: project.name, branch: branch).path }

    private var request: WorktreeRequest {
        WorktreeRequest(project: project, branch: branch, baseRef: baseRef, agent: profile, model: model,
                        task: task, globalPrompt: globalPrompt, sendInitialPrompt: sendInitialPrompt)
    }

    private var composed: Result<String?, Error> {
        Result { try Workspace.composePrompt(request, config: (try? config.get()) ?? BullpenConfig(), path: path) }
    }

    var body: some View {
        Form {
            Section("Worktree en \(project.name)") {
                TextField("Rama", text: $branch, prompt: Text("luis/fix-login"))
                TextField("Base", text: $baseRef, prompt: Text("main"))
                if !branch.isEmpty {
                    LabeledContent("Carpeta") {
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            ConfigSummary(config: config)
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
                    .disabled(branch.isEmpty || baseRef.isEmpty || isCreating || isPromptInvalid || isConfigInvalid)
            }
        }
        .onAppear {
            baseRef = project.defaultBaseRef ?? "main"
            config = Result { try BullpenConfig.load(from: URL(fileURLWithPath: project.path)) }
        }
        .task { await detectInstalledAgents() }
    }

    private var isConfigInvalid: Bool {
        if case .failure = config { return true }
        return false
    }

    private var isPromptInvalid: Bool {
        guard profile != nil, case .failure = composed else { return false }
        return true
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        guard let worktree = await store.createWorktree(request) else { return }
        onCreated(worktree)
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
