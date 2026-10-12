import BPAgents
import BPCore
import BPEnv
import BPGit
import BPPersistence
import BPWorkspace
import SwiftUI

/// Side-by-side view of a fan-out run (PLAN §11.2): what each agent changed, whether it passes
/// [verify], an optional verdict from the judge model, and "keep this one".
struct RunCompareView: View {
    let runID: UUID
    let project: Project
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention
    @Environment(Navigation.self) private var navigation
    @State private var run: Run?
    @State private var members: [Worktree] = []
    @State private var stats: [UUID: (files: Int, added: Int, removed: Int)] = [:]
    @State private var verify: [UUID: [CommandResult]] = [:]
    @State private var busy: String?
    @State private var keep: Worktree?

    private var active: [Worktree] { members.filter { $0.archivedAt == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let run {
                    Text(run.task).font(.title3).textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Rama").bold(); Text("Agente").bold(); Text("Estado").bold()
                        Text("Cambios").bold(); Text("Verificación").bold(); Text("")
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(members) { wt in
                        GridRow {
                            Button(wt.branch) { navigation.selection = wt.id }
                                .buttonStyle(.link)
                                .disabled(wt.archivedAt != nil)
                            Text([AgentProfile.named(wt.agentProfileID)?.name, wt.agentModel].compactMap { $0 }.joined(separator: " · "))
                            Text(wt.archivedAt != nil ? "archivado" : attention.statuses[wt.id]?.state.label ?? "—")
                                .foregroundStyle(.secondary)
                            Text(stats[wt.id].map { "\($0.files) fich. +\($0.added) −\($0.removed)" } ?? "—")
                                .font(.callout.monospacedDigit())
                            verifyCell(wt)
                            if wt.archivedAt == nil, active.count > 1 {
                                Button("Elegir esta") { keep = wt }.help("Quedarte con esta y archivar las demás")
                            } else {
                                Text("")
                            }
                        }
                    }
                }
                HStack {
                    Button("Verificar todos", systemImage: "checkmark.seal") { Task { await verifyAll() } }
                    Button("Pedir veredicto al juez", systemImage: "scalemass") { Task { await askJudge() } }
                    if let busy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                }
                .disabled(busy != nil || active.isEmpty)
                if let verdict = run?.verdict {
                    GroupBox("Veredicto (\(ModelService.choice(for: .judge).model)) — es una opinión, decides tú") {
                        Text((try? AttributedString(markdown: verdict, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(verdict))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .task(id: runID) { await load() }
        .alert("¿Quedarte con \(keep?.branch ?? "")?", isPresented: Binding(get: { keep != nil }, set: { if !$0 { keep = nil } })) {
            Button("Archivar las demás", role: .destructive) { if let keep { Task { await keepOnly(keep) } } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se cierran las terminales y se borran las carpetas de las otras ramas (con sus cambios sin commitear). Las ramas se conservan.")
        }
    }

    @ViewBuilder
    private func verifyCell(_ wt: Worktree) -> some View {
        if let results = verify[wt.id] {
            let ok = results.allSatisfy(\.succeeded)
            Label(ok ? "pasa" : "falla", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .help(results.map { "$ \($0.command) → \($0.exitCode)" }.joined(separator: "\n"))
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func load() async {
        run = store.run(id: runID)
        members = store.runMembers(runID)
        guard let repo = try? await Repository.open(at: URL(fileURLWithPath: project.path)) else { return }
        for wt in active {
            if let files = try? await repo.changes(in: URL(fileURLWithPath: wt.path), baseRef: wt.baseRef) {
                stats[wt.id] = (files.count, files.reduce(0) { $0 + $1.additions }, files.reduce(0) { $0 + $1.deletions })
            }
        }
    }

    private func verifyAll() async {
        busy = "Verificando…"
        defer { busy = nil }
        await withTaskGroup(of: (UUID, [CommandResult]).self) { group in
            for wt in active {
                guard let env = try? WorktreeEnvironment.load(project: project, worktree: wt) else { continue }
                group.addTask {
                    (wt.id, await CommandRunner.run(env.config.verify, in: URL(fileURLWithPath: wt.path), environment: env.environment))
                }
            }
            for await (id, results) in group { verify[id] = results }
        }
        if verify.values.allSatisfy(\.isEmpty) {
            store.errorMessage = "Añade [verify] run = [\"…\"] a .bullpen.toml para poder verificar."
        }
    }

    private func askJudge() async {
        guard let run else { return }
        busy = "El juez está comparando…"
        defer { busy = nil }
        do {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            var candidates: [Candidate] = []
            for wt in active {
                let diff = (try? await repo.rawDiff(in: URL(fileURLWithPath: wt.path), baseRef: wt.baseRef)) ?? ""
                candidates.append(Candidate(
                    branch: wt.branch, agent: AgentProfile.named(wt.agentProfileID)?.name ?? "Terminal",
                    diff: diff, verify: verify[wt.id]
                ))
            }
            let verdict = try await ModelService.complete(.judge, .init(
                system: RunJudge.system, prompt: RunJudge.prompt(task: run.task, candidates: candidates),
                maxTokens: 16000, effort: "high"
            ))
            store.saveVerdict(verdict, for: run)
            self.run = store.run(id: runID)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func keepOnly(_ winner: Worktree) async {
        busy = "Archivando las demás…"
        defer { busy = nil }
        for wt in active where wt.id != winner.id {
            await store.removeWorktree(wt, in: project, force: true)
        }
        navigation.selection = winner.id
        await load()
    }
}
