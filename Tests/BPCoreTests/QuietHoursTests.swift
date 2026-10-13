import BPCore
import Foundation
import Testing

@Suite struct QuietHoursTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }

    func at(_ hour: Int, _ minute: Int = 0, day: Int = 13) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func sameDayWindow() {
        let lunch = QuietHours(from: 14 * 60, to: 15 * 60 + 30)
        #expect(!lunch.contains(at(13, 59), calendar: calendar))
        #expect(lunch.contains(at(14), calendar: calendar))
        #expect(lunch.contains(at(15, 29), calendar: calendar))
        #expect(!lunch.contains(at(15, 30), calendar: calendar))
        #expect(lunch.end(after: at(14, 10), calendar: calendar) == at(15, 30))
        #expect(lunch.end(after: at(16), calendar: calendar) == nil)
    }

    @Test func overnightWindow() {
        let night = QuietHours(from: 21 * 60, to: 8 * 60)
        #expect(night.contains(at(23), calendar: calendar))
        #expect(night.contains(at(2), calendar: calendar))
        #expect(!night.contains(at(8), calendar: calendar))
        #expect(!night.contains(at(12), calendar: calendar))
        #expect(night.end(after: at(23), calendar: calendar) == at(8, day: 14))
        #expect(night.end(after: at(2), calendar: calendar) == at(8))
    }

    @Test func emptyWindowNeverSilences() {
        #expect(!QuietHours(from: 600, to: 600).contains(at(10), calendar: calendar))
    }
}
