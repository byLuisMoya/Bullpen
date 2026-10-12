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

    var body: some Scene {
        WindowGroup("Bullpen", id: "main") {
            ContentView()
                .environment(store)
                .environment(sessions)
                .environment(attention)
                .environment(repoStatus)
                .environment(navigation)
                .environment(reviewNotes)
                .task { await store.start() }
                .task { await sessions.startPolling() }
                .task { await attention.start(store: store, sessions: sessions) }
                .task { await repoStatus.start(store: store) }
                .task { await DebugSnapshots.run(store: store, navigation: navigation) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await repoStatus.refresh(store: store, includePRs: true) }
                }
                .frame(minWidth: 900, minHeight: 560)
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
