import SwiftUI

struct SettingsView: View {
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
                Text("Se antepone al prompt de cada proyecto en todos los worktrees nuevos.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
    }
}
