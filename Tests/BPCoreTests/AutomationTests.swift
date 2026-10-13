import BPCore
import Foundation
import Testing

@Suite struct AutomationTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // 2026-10-12 is a Monday.
    func weekdaysAt9(created: Date) -> Automation {
        Automation(name: "Revisar dependencias", projectID: UUID(), task: "x", weekdays: [2, 3, 4, 5, 6], hour: 9, createdAt: created)
    }

    @Test func runsOncePerScheduledTime() {
        var auto = weekdaysAt9(created: date(11, 20))
        #expect(!auto.isDue(at: date(12, 8, 59), calendar: calendar))
        #expect(auto.isDue(at: date(12, 9, 0), calendar: calendar))
        auto.lastRun = date(12, 9, 0)
        #expect(!auto.isDue(at: date(12, 15), calendar: calendar))
        #expect(auto.isDue(at: date(13, 9, 1), calendar: calendar))
    }

    @Test func skipsWeekendsAndCatchesUpOnce() {
        var auto = weekdaysAt9(created: date(9, 10))   // created Friday
        auto.lastRun = date(9, 9)
        #expect(!auto.isDue(at: date(10, 12), calendar: calendar), "Saturday")
        #expect(!auto.isDue(at: date(11, 12), calendar: calendar), "Sunday")
        // Mac opened Monday at 11: catches up the 9:00 run once.
        #expect(auto.isDue(at: date(12, 11), calendar: calendar))
        // Opened Monday at 23:00, more than 12 h late: skipped.
        #expect(!auto.isDue(at: date(12, 23), calendar: calendar))
        #expect(auto.nextOccurrence(after: date(10, 12), calendar: calendar) == date(12, 9))
    }

    @Test func notBeforeItWasCreatedNorWhenOff() {
        var auto = weekdaysAt9(created: date(12, 10))
        #expect(!auto.isDue(at: date(12, 11), calendar: calendar), "created after today's 9:00")
        auto.enabled = false
        #expect(!auto.isDue(at: date(13, 9, 5), calendar: calendar))
    }

    @Test func branchNamesCarryTheDate() {
        #expect(weekdaysAt9(created: .now).branchName(on: date(13, 9), calendar: calendar) == "auto/revisar-dependencias-1013")
    }
}
