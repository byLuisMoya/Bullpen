import Foundation

/// A scheduled task: on the chosen days at a time, Bullpen creates a worktree in a project and
/// starts an agent on the task ("every morning, check the dependencies").
public struct Automation: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var projectID: UUID
    /// Agent profile id; nil starts the main agent.
    public var agentID: String?
    public var task: String
    /// Days it runs, 1 = Sunday … 7 = Saturday (Calendar weekdays).
    public var weekdays: Set<Int>
    public var hour: Int
    public var minute: Int
    public var enabled: Bool
    public var lastRun: Date?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, projectID: UUID, agentID: String? = nil, task: String,
                weekdays: Set<Int> = [2, 3, 4, 5, 6], hour: Int = 9, minute: Int = 0, enabled: Bool = true,
                lastRun: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.agentID = agentID
        self.task = task
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
        self.enabled = enabled
        self.lastRun = lastRun
        self.createdAt = createdAt
    }

    /// The latest scheduled time at or before `now` (looking back a week), if any.
    public func lastOccurrence(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        for back in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  time <= now else { continue }
            return time
        }
        return nil
    }

    /// The next scheduled time after `now`.
    public func nextOccurrence(after now: Date, calendar: Calendar = .current) -> Date? {
        for ahead in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: now),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  time > now else { continue }
            return time
        }
        return nil
    }

    /// Whether it should run now: a scheduled time has passed since it last ran (or since it was
    /// created), recently enough. A Mac that was asleep or closed catches up once, not per day missed.
    public func isDue(at now: Date, catchUp: TimeInterval = 12 * 3600, calendar: Calendar = .current) -> Bool {
        guard enabled, let occurrence = lastOccurrence(atOrBefore: now, calendar: calendar) else { return false }
        guard now.timeIntervalSince(occurrence) <= catchUp else { return false }
        return occurrence > (lastRun ?? createdAt)
    }

    /// `auto/revisar-dependencias-1013` for a run on 13 October.
    public func branchName(on date: Date, calendar: Calendar = .current) -> String {
        let slug = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").prefix(5).joined(separator: "-")
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "auto/%@-%02d%02d", slug.isEmpty ? "tarea" : slug, parts.month ?? 0, parts.day ?? 0)
    }
}
