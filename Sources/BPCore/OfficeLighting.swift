/// How an office (project) is lit, derived only from how many active worktrees it has (PLAN §9.2).
public enum OfficeLighting: Equatable, Sendable {
    /// No worktrees: lights off, nobody inside.
    case off
    /// One worktree: only that employee's desk lamp is on.
    case singleDesk
    /// Two or more worktrees: every light in the office is on.
    case allOn

    public init(activeWorktrees: Int) {
        switch activeWorktrees {
        case ..<1: self = .off
        case 1: self = .singleDesk
        default: self = .allOn
        }
    }
}
