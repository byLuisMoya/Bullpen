import BPCore
import Foundation
import Testing

@Suite struct SeasonTests {
    func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test(arguments: [
        (10, 14, Season.regular), (10, 15, .halloween), (10, 31, .halloween), (11, 1, .regular),
        (12, 19, .regular), (12, 20, .christmas), (12, 31, .christmas), (1, 1, .christmas), (1, 6, .christmas), (1, 7, .regular),
        (6, 15, .regular),
    ])
    func seasonsByDate(month: Int, day d: Int, expected: Season) {
        #expect(Season.of(day(month, d)) == expected)
    }

    @Test func onlySeasonsHaveTheirOwnIcon() {
        #expect(Season.regular.iconResource == nil)
        #expect(Season.halloween.iconResource == "AppIcon-halloween")
    }
}
