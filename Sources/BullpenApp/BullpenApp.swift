import BPCore
import BPPersistence
import SwiftUI

@main
struct BullpenApp: App {
    @State private var store = BuildingStore()
    @State private var sessions = SessionManager()
    @State private var attention = AttentionCenter()
    @State private var repoStatus = RepoStatusCenter()
    @State private var navigation = Navigation()
    @State private var reviewNotes = ReviewNotes()
    @State private var usage = UsageCenter()

    var body: some Scene {
        WindowGroup("Bullpen", id: "main") {
            ContentView()
                .environment(store)
                .environment(sessions)
                .environment(attention)
                .environment(repoStatus)
                .environment(navigation)
                .environment(reviewNotes)
                .environment(usage)
                .task { await usage.start(store: store, sessions: sessions) }
                .task {
                    store.connectToDaemon = { [sessions] in try await sessions.connection() }
                    store.hooks = sessions.hooks
                    await store.start()
                }
                .task { await sessions.startPolling() }
                .task { await attention.start(store: store, sessions: sessions) }
                .task { await repoStatus.start(store: store) }
                .task { await DebugSnapshots.run(store: store, navigation: navigation) }
                .onChange(of: store.offices.flatMap { $0.worktrees.map(\.id) }) { _, _ in
                    Task { await repoStatus.refresh(store: store, includePRs: true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await repoStatus.refresh(store: store, includePRs: true) }
                }
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                OpenUsageButton()
            }
        }
        Window("Uso", id: "usage") {
            UsageWindow()
                .environment(store)
                .environment(usage)
        }
        Settings {
            SettingsView()
        }
        MenuBarExtra {
            MenuBarContent()
                .environment(store)
                .environment(attention)
                .environment(navigation)
        } label: {
            MenuBarLabel()
                .environment(store)
                .environment(attention)
        }
    }
}

private struct OpenUsageButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Uso y coste") { openWindow(id: "usage") }
            .keyboardShortcut("u", modifiers: [.command, .shift])
    }
}
