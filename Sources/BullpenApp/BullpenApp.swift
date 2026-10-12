import BPCore
import BPPersistence
import SwiftUI

@main
struct BullpenApp: App {
    @State private var store = BuildingStore()

    var body: some Scene {
        WindowGroup("Bullpen") {
            ContentView()
                .environment(store)
                .task { await store.start() }
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
