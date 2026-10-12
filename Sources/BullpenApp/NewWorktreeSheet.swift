import BPAgents
import BPCore
import BPGit
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

    private var profile: AgentProfile? { AgentProfile.named(agentID) }
    private var path: String { WorktreeLocation.path(project: project.name, branch: branch).path }

    private var composed: Result<String?, Error> {
        Result {
            try PromptComposer.compose(
                global: sendInitialPrompt ? globalPrompt : nil,
                project: sendInitialPrompt ? project.initialPrompt : nil,
                task: task,
                variables: PromptComposer.variables(
                    projectName: project.name, branch: branch, baseRef: baseRef, path: path, task: task.nilIfBlank
                )
            )
        }
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
                    Toggle("Incluir prompt inicial (global y del proyecto)", isOn: $sendInitialPrompt)
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
                    .disabled(branch.isEmpty || baseRef.isEmpty || isCreating || isPromptInvalid)
            }
        }
        .onAppear { baseRef = project.defaultBaseRef ?? "main" }
        .task { await detectInstalledAgents() }
    }

    private var isPromptInvalid: Bool {
        guard profile != nil, case .failure = composed else { return false }
        return true
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        guard let worktree = await store.createWorktree(
            in: project, branch: branch, baseRef: baseRef,
            agent: profile?.id, model: model, task: task
        ) else { return }
        if let profile, case let .success(prompt) = composed {
            let command = profile.command(model: model.nilIfBlank, prompt: prompt, hooks: sessions.hooks)
            do {
                try await sessions.startAgent(for: worktree, command: command)
            } catch {
                store.errorMessage = "Worktree creado, pero el agente no arrancó: \(error.localizedDescription)"
            }
        }
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
