import BPCore
import BPPersistence
import SwiftUI

struct ContentView: View {
    @Environment(BuildingStore.self) private var store
    @State private var selection: UUID?
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.offices) { office in
                    Section {
                        ForEach(office.worktrees) { worktree in
                            Label(worktree.branch, systemImage: "person.fill")
                                .tag(worktree.id)
                        }
                    } header: {
                        OfficeHeader(office: office)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button("Añadir proyecto", systemImage: "plus") { isImporting = true }
            }
        } detail: {
            if let error = store.loadError {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.offices.isEmpty {
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
            if case let .success(url) = result { store.addProject(at: url) }
        }
    }
}

private struct OfficeHeader: View {
    let office: Office

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(office.lighting == .off ? Color.secondary : Color.yellow)
            Text(office.project.name)
            Spacer()
            Text("\(office.worktrees.count)").foregroundStyle(.secondary)
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
