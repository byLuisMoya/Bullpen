import BPGit
import BPProviders
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PromptSettings().tabItem { Label("Prompt", systemImage: "text.bubble") }
            ModelSettings().tabItem { Label("Modelos", systemImage: "cpu") }
            LimitSettings().tabItem { Label("Límites", systemImage: "gauge.with.dots.needle.33percent") }
            IntegrationSettings().tabItem { Label("Integraciones", systemImage: "link") }
            CommandLineSettings().tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 600, height: 460)
    }
}

private struct PromptSettings: View {
    @AppStorage("globalInitialPrompt") private var globalPrompt = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $globalPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                Text(PromptVariablesHelp.text).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Prompt inicial global")
            } footer: {
                Text("Se antepone al prompt del repo y del proyecto en todos los worktrees nuevos.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Keys (Keychain) and which model does what. Only for Bullpen's own small jobs; agents use their own accounts.
private struct ModelSettings: View {
    @State private var keys: [ProviderID: String] = [:]
    @State private var quick = ModelService.choice(for: .quick)
    @State private var judge = ModelService.choice(for: .judge)
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                ChoiceEditor(title: "Tareas rápidas", note: "Nombres de rama, resúmenes cortos", choice: $quick)
                ChoiceEditor(title: "Juez", note: "Compara los resultados de varios agentes", choice: $judge)
                HStack {
                    Button("Probar tareas rápidas") { Task { await test() } }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            } header: {
                Text("Modelos de Bullpen")
            } footer: {
                Text("Son opcionales: sin ellos, Bullpen funciona igual y estas funciones se ocultan o piden configuración.")
            }
            Section("Claves (se guardan en el Llavero)") {
                ForEach(ProviderID.allCases.filter(\.needsKey)) { provider in
                    SecureField(provider.name, text: Binding(
                        get: { keys[provider] ?? "" },
                        set: { keys[provider] = $0 }
                    ))
                    .onSubmit { save(provider) }
                }
                Button("Guardar claves") { ProviderID.allCases.filter(\.needsKey).forEach(save) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for provider in ProviderID.allCases where provider.needsKey {
                keys[provider] = ModelService.keys.key(for: provider) ?? ""
            }
        }
        .onChange(of: quick) { _, value in ModelService.setChoice(value, for: .quick) }
        .onChange(of: judge) { _, value in ModelService.setChoice(value, for: .judge) }
    }

    private func save(_ provider: ProviderID) {
        try? ModelService.keys.setKey(keys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
    }

    private func test() async {
        ProviderID.allCases.filter(\.needsKey).forEach(save)
        testResult = "Probando…"
        do {
            testResult = "✓ " + (try await ModelService.suggestBranchName(for: "Arreglar el timeout del login", project: "demo"))
        } catch {
            testResult = "✗ " + error.localizedDescription
        }
    }
}

private struct ChoiceEditor: View {
    let title: String
    let note: String
    @Binding var choice: ModelChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Proveedor", selection: $choice.provider) {
                    ForEach(ProviderID.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Modelo", text: $choice.model)
                if !choice.provider.suggestedModels.isEmpty {
                    Menu("Sugerencias") {
                        ForEach(choice.provider.suggestedModels, id: \.self) { m in Button(m) { choice.model = m } }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

private struct LimitSettings: View {
    @AppStorage("limits.maxAgents") private var maxAgents = 0
    @AppStorage("limits.dailyBudget") private var dailyBudget = 0.0

    var body: some View {
        Form {
            Section {
                Stepper(maxAgents == 0 ? "Agentes a la vez: sin límite" : "Agentes a la vez: \(maxAgents)", value: $maxAgents, in: 0...30)
                TextField("Presupuesto diario (USD, 0 = sin límite)", value: $dailyBudget, format: .number)
            } footer: {
                Text("Al crear worktrees con agente, Bullpen avisa si se supera alguno de estos límites. El gasto es una estimación a precios de API (ventana Uso, ⌘⇧U).")
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationSettings: View {
    @State private var linearKey = ""
    @AppStorage("tickets.updateLinear") private var updateLinear = true

    var body: some View {
        Form {
            Section {
                LabeledContent("GitHub", value: GitHubCLI.locate() == nil ? "instala gh y ejecuta gh auth login" : "usa tu sesión de gh")
            } header: {
                Text("GitHub")
            } footer: {
                Text("Los issues abiertos del repo aparecen en «Desde ticket…». Las PR incluyen «Closes #n».")
            }
            Section {
                SecureField("Clave personal de Linear", text: $linearKey)
                    .onSubmit(save)
                Toggle("Mover a In Progress al crear y a In Review al abrir la PR", isOn: $updateLinear)
                Button("Guardar", action: save)
            } header: {
                Text("Linear")
            } footer: {
                Text("Crea la clave en Linear › Settings › API. Se guarda en el Llavero. Para ver solo un equipo, pon [integrations] linear_team = \"FKPI\" en .bullpen.toml.")
            }
        }
        .formStyle(.grouped)
        .onAppear { linearKey = ModelService.keys.secret("linear") ?? "" }
    }

    private func save() {
        try? ModelService.keys.setSecret(linearKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "linear", label: "Linear")
    }
}

private struct CommandLineSettings: View {
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button("Instalar el comando bp") {
                    do { message = try AppActions.installCLI() } catch { message = error.localizedDescription }
                }
                Text("Crea ~/.local/bin/bp apuntando a esta app: bp wt list, bp wt create, bp wt send…").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Comando bp") }
            Section {
                Text(AppActions.mcpCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copiar comando") {
                    AppActions.copy(AppActions.mcpCommand)
                    message = "Copiado. Pégalo en una terminal para que Claude Code pueda manejar Bullpen."
                }
            } header: { Text("Bullpen como servidor MCP") } footer: {
                Text("Con esto, un agente puede listar worktrees, crear otros con su tarea, enviarles mensajes y leer sus terminales.")
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
