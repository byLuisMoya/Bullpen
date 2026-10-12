import BPCore
import SwiftUI

/// Edits the prompt sent to the agent every time a worktree is created in this project (PLAN §6.5).
struct ProjectPromptSheet: View {
    @State var project: Project
    @Environment(BuildingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt inicial de \(project.name)").font(.headline)
            Text("Se envía al agente cada vez que creas un worktree en este proyecto, después del prompt global y antes de la tarea.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .border(.separator)
            Text(PromptVariablesHelp.text).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    project.initialPrompt = text.nilIfBlank
                    store.updateProject(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear { text = project.initialPrompt ?? "" }
    }
}

enum PromptVariablesHelp {
    static let text = "Variables: {{project.name}} {{worktree.branch}} {{worktree.baseRef}} {{worktree.path}} {{task.description}} {{user.name}}"
}
