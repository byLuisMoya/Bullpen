import Foundation
import Observation

/// What the main window shows; shared with the menu bar so it can jump to a worktree.
@MainActor
@Observable
final class Navigation {
    /// Selected worktree; nil shows the building.
    var selection: UUID?
}
