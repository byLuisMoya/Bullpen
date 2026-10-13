import BPAgents
import BPCore
import BPGit
import BPProviders
import BPSessions
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PromptSettings().tabItem { Label("Prompt", systemImage: "text.bubble") }
            ModelSettings().tabItem { Label("Modelos", systemImage: "cpu") }
            LimitSettings().tabItem { Label("Límites", systemImage: "gauge.with.dots.needle.33percent") }
            AutomationSettings().tabItem { Label("Automatizaciones", systemImage: "clock.badge.checkmark") }
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
                    LabeledContent(provider.name) {
                        SecureField(provider.name, text: Binding(
                            get: { keys[provider] ?? "" },
                            set: { keys[provider] = $0 }
                        ))
                        .labelsHidden()
                        .frame(width: 100)
                        .onSubmit { save(provider) }
                    }
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
                LabeledContent("Clave personal de Linear") {
                    // Narrow on purpose: the key is hidden, a full-width row is only dots.
                    SecureField("Clave personal de Linear", text: $linearKey, prompt: Text("lin_api…"))
                        .labelsHidden()
                        .frame(width: 100)
                        .onSubmit(save)
                }
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

private struct GeneralSettings: View {
    @AppStorage(BuildingName.key) private var buildingName = BuildingName.standard
    @AppStorage(PrimaryAgent.key) private var primaryAgent = AgentProfile.claude.id
    @AppStorage(AgentHooks.coordinationKey) private var coordination = true
    @State private var addingAgent = false
    /// Bumped after adding or removing a custom agent, to re-read the list.
    @State private var agentsVersion = 0

    var body: some View {
        let agents = { _ = agentsVersion; return AgentProfile.all }()
        Form {
            Section {
                Picker("Agente principal", selection: $primaryAgent) {
                    ForEach(agents) { Text($0.name).tag($0.id) }
                }
                Toggle("Los agentes pueden coordinarse entre worktrees", isOn: $coordination)
                    .help("Claude Code y Codex arrancan con el servidor MCP de Bullpen: pueden crear worktrees, delegar tareas en otros agentes y esperar sus respuestas. Se aplica a los agentes que arranquen a partir de ahora.")
            } header: {
                Text("Agentes")
            } footer: {
                Text("Se abre en los worktrees nuevos y en los que vengan de Orca. Junto a Ajustes ves cuánto lleva usado: el porcentaje de la sesión de 5 h y de la semana si es una suscripción (Claude, ChatGPT), o los tokens de hoy si pagas por uso (Claude, Codex).")
            }
            Section {
                ForEach(agents.filter(\.isCustom)) { agent in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(agent.name)
                            Text(([agent.executable] + agent.arguments).joined(separator: " "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Quitar", role: .destructive) {
                            try? AgentProfile.deleteCustom(agent.id)
                            if primaryAgent == agent.id { primaryAgent = AgentProfile.claude.id }
                            agentsVersion += 1
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Añadir agente…", systemImage: "plus") { addingAgent = true }
            } header: {
                Text("Agentes personalizados")
            } footer: {
                Text("Cualquier agente de terminal que no venga de serie (por ejemplo DeepSeek): lo añades con su comando y puedes elegirlo como principal.")
            }
            Section {
                TextField("Nombre de la vista general", text: $buildingName, prompt: Text(BuildingName.standard))
                Button("Restablecer") { buildingName = BuildingName.standard }
                    .disabled(buildingName == BuildingName.standard)
            } header: {
                Text("Vista general")
            } footer: {
                Text("Cómo se llama la pantalla con todas las oficinas (por ejemplo «Edificio», «Oficinas» o «Campus»).")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingAgent) {
            CustomAgentSheet { saved in
                agentsVersion += 1
                primaryAgent = saved.id
            }
        }
    }
}

/// Adds any terminal agent: a name, the command that starts it, and how it takes its first task.
private struct CustomAgentSheet: View {
    var onSaved: (AgentProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var delivery = 0
    @State private var promptFlag = "--prompt"
    @State private var modelFlag = ""
    @State private var mcpMode = 0
    @State private var usage = "auto"
    @State private var mcpFlag = "--mcp-config"
    @State private var error: String?

    private var found: Bool? {
        guard let executable = command.split(separator: " ").first.map(String.init), !executable.isEmpty else { return nil }
        return ShellEnvironment.locate(executable) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $name, prompt: Text("DeepSeek"))
                TextField("Comando", text: $command, prompt: Text("deepseek  ·  aider --model deepseek/deepseek-chat"))
                    .font(.body.monospaced())
                if let found {
                    Label(found ? "Encontrado en tu PATH" : "No se encuentra en tu PATH (puedes guardarlo igualmente)",
                          systemImage: found ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(found ? Color.secondary : Color.orange)
                }
            }
            Section("La tarea inicial") {
                Picker("Se la pasa", selection: $delivery) {
                    Text("Como argumento (comando \"tarea\")").tag(0)
                    Text("Con una opción").tag(1)
                    Text("Escribiéndola cuando arranque").tag(2)
                }
                if delivery == 1 {
                    TextField("Opción", text: $promptFlag, prompt: Text("--prompt"))
                }
                TextField("Opción del modelo (opcional)", text: $modelFlag, prompt: Text("--model"))
            }
            Section {
                Picker("Servidores MCP", selection: $mcpMode) {
                    Text("No los usa").tag(0)
                    Text("Opción con el JSON").tag(1)
                    Text("Opción con la ruta de un fichero").tag(2)
                    Text("Fichero .mcp.json en el worktree").tag(3)
                }
                if mcpMode == 1 || mcpMode == 2 {
                    TextField("Opción", text: $mcpFlag, prompt: Text("--mcp-config"))
                }
                Picker("Uso junto a Ajustes", selection: $usage) {
                    Text("Automático (por el nombre o el comando)").tag("auto")
                    Text("Saldo de DeepSeek").tag("deepseek")
                    Text("Saldo de OpenRouter").tag("openrouter")
                    Text("No mostrar").tag("none")
                }
            } header: {
                Text("Coordinación y uso")
            } footer: {
                Text("Con MCP recibe el servidor de Bullpen y puede delegar en otros agentes y esperar sus respuestas (el .mcp.json se deja fuera de git). El saldo se lee con la clave de Ajustes › Modelos.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Añadir") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        let prompt: PromptDelivery = switch delivery {
        case 1: .flag(promptFlag.trimmingCharacters(in: .whitespaces))
        case 2: .type
        default: .positional
        }
        do {
            let flag = mcpFlag.trimmingCharacters(in: .whitespaces)
            let mcp: MCPDelivery? = switch mcpMode {
            case 1: .inlineJSON(flag)
            case 2: .file(flag)
            case 3: .projectFile
            default: nil
            }
            let saved = try AgentProfile.saveCustom(name: name.trimmingCharacters(in: .whitespaces), command: command,
                                                    prompt: prompt, modelFlag: modelFlag.trimmingCharacters(in: .whitespaces), mcp: mcp,
                                                    usage: usage == "auto" ? nil : usage)
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Scheduled tasks: on chosen days at a time, a worktree with its agent on a task.
private struct AutomationSettings: View {
    @Environment(BuildingStore.self) private var store
    @State private var editing: Automation?
    @State private var running: UUID?

    var body: some View {
        Form {
            Section {
                if store.automations.isEmpty {
                    Text("Ninguna todavía.").foregroundStyle(.secondary)
                }
                ForEach(store.automations) { automation in
                    HStack {
                        Toggle("", isOn: Binding(get: { automation.enabled }, set: { on in
                            var changed = automation
                            changed.enabled = on
                            store.save(changed)
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(automation.name)
                            Text(summary(automation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(running == automation.id ? "Creando…" : "Ejecutar ahora") {
                            Task {
                                running = automation.id
                                await store.run(automation)
                                running = nil
                            }
                        }
                        .disabled(running != nil)
                        Button("Editar") { editing = automation }
                    }
                }
                Button("Nueva automatización…", systemImage: "plus") {
                    guard let project = store.offices.first?.project else { return }
                    editing = Automation(name: "", projectID: project.id, task: "")
                }
                .disabled(store.offices.isEmpty)
            } footer: {
                Text("A la hora indicada, Bullpen crea un worktree en el proyecto (rama auto/<nombre>-<fecha>) y arranca el agente con la tarea. Si el Mac estaba dormido o Bullpen cerrado, se ejecuta una vez al volver, si no han pasado más de 12 h.")
            }
        }
        .formStyle(.grouped)
        .onAppear { store.reloadAutomations() }
        .sheet(item: $editing) { automation in
            AutomationEditor(automation: automation, isNew: !store.automations.contains { $0.id == automation.id })
        }
    }

    private func summary(_ a: Automation) -> String {
        let project = store.offices.first { $0.project.id == a.projectID }?.project.name ?? "?"
        let agent = AgentProfile.named(a.agentID)?.name ?? "agente principal"
        let next = a.nextOccurrence(after: Date()).map { "próxima: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "sin días"
        return "\(project) · \(agent) · \(AutomationEditor.daysText(a.weekdays)) a las \(String(format: "%02d:%02d", a.hour, a.minute)) · \(next)"
    }
}

private struct AutomationEditor: View {
    @State var automation: Automation
    let isNew: Bool
    @Environment(BuildingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Monday first, as in Spain.
    static let days: [(Int, String)] = [(2, "L"), (3, "M"), (4, "X"), (5, "J"), (6, "V"), (7, "S"), (1, "D")]

    static func daysText(_ set: Set<Int>) -> String {
        if set == [2, 3, 4, 5, 6] { return "de lunes a viernes" }
        if set.count == 7 { return "todos los días" }
        return days.filter { set.contains($0.0) }.map(\.1).joined(separator: " ")
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: automation.hour, minute: automation.minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                automation.hour = Calendar.current.component(.hour, from: date)
                automation.minute = Calendar.current.component(.minute, from: date)
            }
        )
    }

    var body: some View {
        Form {
            TextField("Nombre", text: $automation.name, prompt: Text("Revisar dependencias"))
            Picker("Proyecto", selection: $automation.projectID) {
                ForEach(store.offices) { Text($0.project.name).tag($0.project.id) }
            }
            Picker("Agente", selection: Binding(get: { automation.agentID ?? "" }, set: { automation.agentID = $0.isEmpty ? nil : $0 })) {
                Text("Agente principal").tag("")
                ForEach(AgentProfile.all) { Text($0.name).tag($0.id) }
            }
            HStack {
                Text("Días")
                Spacer()
                ForEach(Self.days, id: \.0) { day, letter in
                    let on = automation.weekdays.contains(day)
                    Button(letter) {
                        if on { automation.weekdays.remove(day) } else { automation.weekdays.insert(day) }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .fontWeight(on ? .bold : .regular)
                }
            }
            DatePicker("Hora", selection: time, displayedComponents: .hourAndMinute)
            VStack(alignment: .leading) {
                Text("Tarea")
                TextEditor(text: $automation.task)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
            if !isNew {
                Button("Borrar automatización", role: .destructive) {
                    store.delete(automation)
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Guardar") {
                    store.save(automation)
                    dismiss()
                }
                .disabled(automation.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || automation.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || automation.weekdays.isEmpty)
            }
        }
    }
}
