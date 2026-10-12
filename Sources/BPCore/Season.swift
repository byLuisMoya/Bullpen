import Foundation

/// Which Dock icon the app shows (the Finder always shows the regular one).
public enum Season: String, CaseIterable, Sendable {
    /// Dusk building: the rest of the year.
    case regular
    /// Night building, 15–31 October.
    case halloween
    /// Snowy building, 20 December – 6 January.
    case christmas

    public static func of(_ date: Date, calendar: Calendar = .current) -> Season {
        let c = calendar.dateComponents([.month, .day], from: date)
        switch (c.month ?? 0, c.day ?? 0) {
        case (10, 15...31): return .halloween
        case (12, 20...31), (1, 1...6): return .christmas
        default: return .regular
        }
    }

    /// Image resource in the app bundle; nil means the regular app icon.
    public var iconResource: String? {
        switch self {
        case .regular: nil
        case .halloween: "AppIcon-halloween"
        case .christmas: "AppIcon-christmas"
        }
    }
}
