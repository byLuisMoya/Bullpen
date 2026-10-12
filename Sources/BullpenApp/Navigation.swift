import Foundation
import Observation
import SwiftUI

/// What the main window shows; shared with the menu bar so it can jump to a worktree.
@MainActor
@Observable
final class Navigation {
    /// Selected worktree; nil shows the building.
    var selection: UUID?
    /// Sidebar shown or hidden (kept here so it can be driven programmatically, e.g. by DebugSnapshots).
    var columnVisibility: NavigationSplitViewVisibility = .all

    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }
}

/// What the main overview is called ("Edificio" by default); set in Settings › General.
enum BuildingName {
    static let key = "buildingName"
    static let standard = "Edificio"
    static var current: String {
        let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? standard : value
    }
}
