import BPCore
import BPPersistence
import SwiftUI

@main
struct BullpenApp: App {
    @State private var store = BuildingStore()
    @State private var sessions = SessionManager()
    @State private var attention = AttentionCenter()
    @State private var repoStatus = RepoStatusCenter()

    var body: some Scene {
        WindowGroup("Bullpen") {
            ContentView()
                .environment(store)
                .environment(sessions)
                .environment(attention)
                .environment(repoStatus)
                .task { await store.start() }
                .task { await sessions.startPolling() }
                .task { await attention.start(store: store, sessions: sessions) }
                .task { await repoStatus.start(store: store) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await repoStatus.refresh(store: store, includePRs: true) }
                }
                .frame(minWidth: 900, minHeight: 560)
        }
        Settings {
            SettingsView()
        }
    }
}
