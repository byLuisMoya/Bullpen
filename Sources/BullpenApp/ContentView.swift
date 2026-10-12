import BPCore
import BPGit
import BPPersistence
import SwiftUI

struct ContentView: View {
    @Environment(BuildingStore.self) private var store
    @State private var selection: UUID?
    @State private var isImporting = false
    @State private var newWorktreeFor: Project?
    @State private var pendingRemoval: PendingRemoval?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.offices) { office in
                    Section {
                        ForEach(office.worktrees) { worktree in
                            Label(worktree.branch, systemImage: "person.fill")
                                .tag(worktree.id)
                                .contextMenu {
                                    Button("Mostrar en Finder") {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                                    }
                                    Button("Eliminar worktree…", role: .destructive) {
                                        Task { await confirmRemoval(worktree, in: office.project) }
                                    }
                                }
                        }
                    } header: {
                        OfficeHeader(office: office) { newWorktreeFor = office.project }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button("Añadir proyecto", systemImage: "plus") { isImporting = true }
            }
        } detail: {
            if store.offices.isEmpty {
                ContentUnavailableView(
                    "Edificio vacío",
                    systemImage: "building.2",
                    description: Text("Añade un repositorio git para abrir su oficina.")
                )
            } else {
                ContentUnavailableView("Bullpen \(Bullpen.version)", systemImage: "building.2.fill")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                Task { await store.addProject(at: url) }
            }
        }
        .sheet(item: $newWorktreeFor) { project in
            NewWorktreeSheet(project: project)
        }
        .alert(
            "¿Eliminar \(pendingRemoval?.worktree.branch ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { removal in
            Button(removal.guards.isEmpty ? "Eliminar" : "Eliminar igualmente", role: .destructive) {
                Task { await store.removeWorktree(removal.worktree, in: removal.project, force: !removal.guards.isEmpty) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { removal in
            if removal.guards.isEmpty {
                Text("Se borra la carpeta del worktree. La rama se conserva.")
            } else {
                Text("Se perdería:\n" + removal.guards.map { "• " + $0.message }.joined(separator: "\n")
                    + "\n\nLa rama se conserva, pero los cambios sin commitear se pierden.")
            }
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

    private func confirmRemoval(_ worktree: Worktree, in project: Project) async {
        let guards = await store.removalGuards(for: worktree, in: project)
        pendingRemoval = PendingRemoval(worktree: worktree, project: project, guards: guards)
    }
}

private struct PendingRemoval {
    var worktree: Worktree
    var project: Project
    var guards: [RemovalGuard]
}

private struct OfficeHeader: View {
    let office: Office
    let onNewWorktree: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(office.lighting == .off ? Color.secondary : Color.yellow)
            Text(office.project.name)
            Spacer()
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

private struct NewWorktreeSheet: View {
    let project: Project
    @Environment(BuildingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var baseRef = ""
    @State private var isCreating = false

    var body: some View {
        Form {
            Section("Nuevo worktree en \(project.name)") {
                TextField("Rama", text: $branch, prompt: Text("luis/fix-login"))
                TextField("Base", text: $baseRef, prompt: Text("main"))
            }
            if !branch.isEmpty {
                Text(WorktreeLocation.path(project: project.name, branch: branch).path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crear") {
                    isCreating = true
                    Task {
                        if await store.createWorktree(in: project, branch: branch, baseRef: baseRef) { dismiss() }
                        isCreating = false
                    }
                }
                .disabled(branch.isEmpty || baseRef.isEmpty || isCreating)
            }
        }
        .onAppear { baseRef = project.defaultBaseRef ?? "main" }
    }
}
