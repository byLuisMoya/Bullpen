import BPCore
import BPPersistence
import SwiftUI

@main
struct BullpenApp: App {
    @State private var store = BuildingStore()
    @State private var sessions = SessionManager()
    @State private var attention = AttentionCenter()

    var body: some Scene {
        WindowGroup("Bullpen") {
            ContentView()
                .environment(store)
                .environment(sessions)
                .environment(attention)
                .task { await store.start() }
                .task { await sessions.startPolling() }
                .task { await attention.start(store: store, sessions: sessions) }
                .frame(minWidth: 900, minHeight: 560)
        }
        Settings {
            SettingsView()
        }
    }
}
