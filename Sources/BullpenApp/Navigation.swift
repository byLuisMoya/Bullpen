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

    /// One explicit curve for showing and hiding the sidebar (the default animation finished
    /// the expansion with a jump). BULLPEN_SIDEBAR_ANIMATION picks an alternative while tuning.
    static var sidebarAnimation: Animation {
        switch ProcessInfo.processInfo.environment["BULLPEN_SIDEBAR_ANIMATION"] {
        case "none": .linear(duration: 0)
        case "spring": .smooth(duration: 0.35)
        default: .easeInOut(duration: 0.28)
        }
    }

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
