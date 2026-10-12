import BPCore
import BPPersistence
import SwiftUI

@main
struct BullpenApp: App {
    @State private var store = BuildingStore()
    @State private var sessions = SessionManager()

    var body: some Scene {
        WindowGroup("Bullpen") {
            ContentView()
                .environment(store)
                .environment(sessions)
                .task { await store.start() }
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
