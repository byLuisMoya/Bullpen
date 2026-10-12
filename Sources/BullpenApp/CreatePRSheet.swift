import BPCore
import BPGit
import SwiftUI

/// Pushes the branch and opens a pull request with `gh` (PLAN §11.4).
/// Title is the branch name, verbatim; base is the worktree's base ref.
struct CreatePRSheet: View {
    let worktree: Worktree
    let project: Project
    @Environment(RepoStatusCenter.self) private var repoStatus
    @Environment(BuildingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var base = ""
    @State private var bodyText = ""
    @State private var draft = false
    @State private var includeLog = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Nueva PR") {
                LabeledContent("Título", value: worktree.branch)
                TextField("Base", text: $base)
                Toggle("Borrador", isOn: $draft)
                if SessionLog.markdown(for: worktree) != nil {
                    Toggle("Añadir la bitácora del agente (plegada)", isOn: $includeLog)
                }
            }
            Section("Descripción") {
                TextEditor(text: $bodyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(working ? "Creando…" : "Subir y crear PR") { Task { await create() } }
                    .disabled(working || base.isEmpty)
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        base = worktree.baseRef
        let repo = try? await Repository.open(at: URL(fileURLWithPath: project.path))
        let commits = (try? await repo?.commitSummaries(in: URL(fileURLWithPath: worktree.path), baseRef: worktree.baseRef)) ?? []
        var text = "## Qué cambia\n\n"
        if let ticket = worktree.ticket { text += "Ticket: [\(ticket.key)](\(ticket.url?.absoluteString ?? ""))\n\n" }
        else { text += "\(worktree.taskDescription ?? "")\n" }
        if !commits.isEmpty {
            text += "\n## Commits\n\n" + commits.reversed().map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        text += "\n## Verificación\n\n- \n"
        bodyText = text
    }

    private func create() async {
        working = true
        defer { working = false }
        guard let gh = GitHubCLI.locate() else {
            error = "No se encuentra `gh`. Instálalo y ejecuta `gh auth login`."
            return
        }
        do {
            let repo = try await Repository.open(at: URL(fileURLWithPath: project.path))
            let path = URL(fileURLWithPath: worktree.path)
            try await repo.push(branch: worktree.branch, from: path)
            let url = try await gh.createPullRequest(
                in: path, base: base, head: worktree.branch, title: worktree.branch,
                body: bodyText + Tickets.pullRequestBodySuffix(worktree.ticket)
                    + (includeLog ? "\n" + (SessionLog.markdown(for: worktree) ?? "") : ""), draft: draft
            )
            await repoStatus.refresh(store: store, includePRs: true)
            if let ref = worktree.ticket {
                try? await Tickets.pullRequestOpened(ref, url: url)
            }
            if let url { NSWorkspace.shared.open(url) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
