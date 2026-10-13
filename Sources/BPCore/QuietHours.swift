import Foundation

/// A daily quiet window, in minutes from midnight; it may cross midnight (21:00 → 08:00).
public struct QuietHours: Equatable, Sendable {
    public var from: Int
    public var to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if from == to { return false }
        return from < to ? (minute >= from && minute < to) : (minute >= from || minute < to)
    }

    /// When the window that contains `date` ends.
    public func end(after date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let start = calendar.startOfDay(for: date)
        let today = calendar.date(byAdding: .minute, value: to, to: start)!
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
