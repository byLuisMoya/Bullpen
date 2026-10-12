import BPCore
import BPEnv
import BPGit
import BPPersistence
import BPWorkspace
import SwiftUI

/// A comment on one line of the worktree's changes, to be sent back to the agent (PLAN §11.1).
struct ReviewComment: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var line: DiffLine
    var text: String
}

/// Review notes per worktree, kept while the app runs.
@MainActor
@Observable
final class ReviewNotes {
    var comments: [UUID: [ReviewComment]] = [:]

    func message(for worktree: UUID) -> String? {
        guard let list = comments[worktree], !list.isEmpty else { return nil }
        var text = "Revisa estos comentarios sobre tus cambios y corrígelos:\n"
        for (i, c) in list.enumerated() {
            let number = c.line.newNumber ?? c.line.oldNumber ?? 0
            let marker = c.line.kind == .removed ? " (línea eliminada)" : ""
            text += "\n\(i + 1). \(c.path):\(number)\(marker)\n   > \(c.line.text.trimmingCharacters(in: .whitespaces))\n   \(c.text)\n"
        }
        return text
    }
}

struct ReviewView: View {
    let worktree: Worktree
    let project: Project
    @Environment(SessionManager.self) private var sessions
    @Environment(ReviewNotes.self) private var notes
    @Environment(RepoStatusCenter.self) private var repoStatus
    @Environment(BuildingStore.self) private var store
    @State private var files: [FileDiff] = []
    @State private var selectedPath: String?
    @State private var loading = false
    @State private var error: String?
    @State private var showingPR = false
    @State private var verifying = false
    @State private var verifyResults: [CommandResult]?

    private var comments: [ReviewComment] { notes.comments[worktree.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(files, selection: $selectedPath) { file in
                    HStack(spacing: 6) {
                        Text(file.status.rawValue)
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(file.status.color)
                            .frame(width: 12)
                        Text(file.path).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                        Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                    }
                    .tag(file.path)
                }
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)

                Group {
                    if let file = files.first(where: { $0.path == selectedPath }) {
                        DiffFileView(file: file, worktreeID: worktree.id)
                    } else if loading {
                        ProgressView()
                    } else if let error {
                        ContentUnavailableView("No se pudo leer el diff", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if files.isEmpty {
                        ContentUnavailableView("Sin cambios", systemImage: "checkmark.circle", description: Text("Nada distinto de \(worktree.baseRef)."))
                    } else {
                        ContentUnavailableView("Elige un fichero", systemImage: "doc.text")
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("\(files.count) fichero(s) · \(comments.count) comentario(s)").foregroundStyle(.secondary)
                Spacer()
                Button("Descartar comentarios", role: .destructive) { notes.comments[worktree.id] = [] }
                    .disabled(comments.isEmpty)
                Button("Enviar al agente") { Task { await sendToAgent() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(comments.isEmpty)
            }
            .padding(8)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Recargar", systemImage: "arrow.clockwise") { Task { await load() } }
                Button(verifying ? "Verificando…" : "Verificar", systemImage: "checkmark.seal") { Task { await verify() } }
                    .disabled(verifying)
                    .help("Ejecuta [verify] de .bullpen.toml en este worktree")
                Button("Crear PR…", systemImage: "arrow.triangle.pull") { showingPR = true }
                    .disabled(repoStatus.pullRequests[worktree.id]?.state == .open || repoStatus.pullRequests[worktree.id]?.state == .draft)
                    .help(repoStatus.pullRequests[worktree.id].map { "Ya existe la PR #\($0.number)" } ?? "Subir la rama y abrir una PR")
            }
        }
        .sheet(isPresented: $showingPR) {
            CreatePRSheet(worktree: worktree, project: project)
        }
        .sheet(isPresented: Binding(get: { verifyResults != nil }, set: { if !$0 { verifyResults = nil } })) {
            VerifyResultsView(results: verifyResults ?? [])
        }
        .task(id: worktree.id) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            files = try await repo.changes(in: URL(fileURLWithPath: worktree.path), baseRef: worktree.baseRef)
            error = nil
            if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) { selectedPath = files.first?.path }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        verifying = true
        defer { verifying = false }
        do {
            let env = try WorktreeEnvironment.load(project: project, worktree: worktree)
            guard !env.config.verify.isEmpty else {
                store.errorMessage = "Añade [verify] run = [\"…\"] a .bullpen.toml para poder verificar."
                return
            }
            verifyResults = await CommandRunner.run(env.config.verify, in: URL(fileURLWithPath: worktree.path), environment: env.environment)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func sendToAgent() async {
        guard let message = notes.message(for: worktree.id) else { return }
        do {
            try await sessions.sendMessage(message, to: worktree)
            notes.comments[worktree.id] = []
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}

private struct DiffFileView: View {
    let file: FileDiff
    let worktreeID: UUID
    @Environment(ReviewNotes.self) private var notes
    @State private var editing: DiffLine?
    @State private var draft = ""

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if file.isBinary { Text("Fichero binario").padding() }
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08))
                    ForEach(hunk.lines) { line in
                        LineRow(line: line) { editing = line; draft = "" }
                        ForEach(comments(on: line)) { comment in
                            CommentBox(text: comment.text) {
                                notes.comments[worktreeID]?.removeAll { $0.id == comment.id }
                            }
                        }
                        if editing == line {
                            HStack {
                                TextField("Comentario para el agente…", text: $draft, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(save)
                                Button("Añadir", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancelar") { editing = nil }
                            }
                            .padding(.horizontal, 90).padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(minWidth: 600, alignment: .leading)
        }
    }

    private func comments(on line: DiffLine) -> [ReviewComment] {
        (notes.comments[worktreeID] ?? []).filter { $0.path == file.path && $0.line == line }
    }

    private func save() {
        guard let line = editing, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        notes.comments[worktreeID, default: []].append(ReviewComment(path: file.path, line: line, text: draft))
        editing = nil
    }
}

private struct LineRow: View {
    let line: DiffLine
    let onComment: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
            Button(action: onComment) {
                Image(systemName: "plus.bubble.fill").foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .frame(width: 22)
            .help("Comentar esta línea")
            Text(marker + line.text)
                .fixedSize()
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .onHover { hovering = $0 }
    }

    private var marker: String {
        switch line.kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .context: .clear
        }
    }
}

private struct CommentBox: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
            Text(text).frame(maxWidth: 560, alignment: .leading)
            Button(action: onDelete) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 104).padding(.vertical, 3)
    }
}

extension FileDiff.Status {
    var color: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed: .blue
        }
    }
}

private struct VerifyResultsView: View {
    let results: [CommandResult]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(results.allSatisfy(\.succeeded) ? "Verificación correcta" : "La verificación ha fallado",
                  systemImage: results.allSatisfy(\.succeeded) ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.headline)
                .foregroundStyle(results.allSatisfy(\.succeeded) ? .green : .red)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("$ \(result.command)  →  \(result.exitCode)").font(.system(.callout, design: .monospaced).bold())
                                .foregroundStyle(result.succeeded ? Color.primary : .red)
                            Text(result.output.suffix(4000)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Cerrar") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 640, height: 420)
    }
}
