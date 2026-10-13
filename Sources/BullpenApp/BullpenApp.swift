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
    @State private var updater = Updater()
    @State private var summaries = SummaryCenter()
    @State private var browsers = BrowserCenter()
    @State private var orca = OrcaCenter()

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
                .environment(updater)
                .environment(summaries)
                .environment(browsers)
                .environment(orca)
                .task { browsers.start() }
                .task {
                    attention.orca = orca
                    summaries.orca = orca
                    sessions.agentRunsElsewhere = { [orca] worktree in (orca.activity(for: worktree)?.liveTerminals ?? 0) > 0 }
                    await orca.start()
                }
                .task { await summaries.start(store: store, sessions: sessions, attention: attention) }
                .task { await usage.start(store: store, sessions: sessions) }
                .task { await updater.start() }
                .task {
                    // After the store has opened the database.
                    while store.workspace == nil { try? await Task.sleep(for: .milliseconds(200)) }
                    await store.runAutomations()
                }
                .task { await SeasonalIcon.keepUpdated() }
                .task {
                    store.connectToDaemon = { [sessions] in try await sessions.connection() }
                    store.hooks = sessions.hooks
                    sessions.adoptAgent = { [store] worktree, agent in store.setAgent(agent, for: worktree) }
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
            CommandGroup(before: .toolbar) {
                Button("Mostrar u ocultar la barra lateral") { withAnimation(Navigation.sidebarAnimation) { navigation.toggleSidebar() } }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                Button("Ver las oficinas") { navigation.selection = nil }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .help) {
                if AppActions.demoAvailable { DemoMenu(store: store) }
            }
        }
        Window("Uso", id: "usage") {
            UsageWindow()
                .environment(store)
                .environment(usage)
        }
        Settings {
            SettingsView()
                .environment(store)
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

private struct DemoMenu: View {
    let store: BuildingStore
    var body: some View {
        Button("Cargar demo (agentes simulados)") { run("start") }
        Button("Quitar demo") { run("stop") }
    }
    private func run(_ action: String) {
        Task { do { try await AppActions.demo(action) } catch { store.errorMessage = error.localizedDescription } }
    }
}
