import Domain
import Foundation
import Testing

struct CalendarDayTests {
    @Test(arguments: ["2026-10-28", "2028-02-29", "2026-01-01", "2026-12-31"])
    func parsesValidDays(_ string: String) throws {
        let day = try #require(CalendarDay(string))
        #expect(day.description == string)
    }

    @Test(arguments: ["2026-02-30", "2027-02-29", "2026-13-01", "2026-00-10", "2026-1-05", "26-10-28", "2026/10/28", "", "abcd-ef-gh", "2026-10-28T00:00"])
    func rejectsInvalidDays(_ string: String) {
        #expect(CalendarDay(string) == nil)
    }

    @Test func addingDaysCrossesMonthAndYearBoundaries() throws {
        let day = try #require(CalendarDay("2026-12-31"))
        #expect(day.adding(days: 1).description == "2027-01-01")
        #expect(day.adding(days: -365).description == "2025-12-31")
        #expect(try #require(CalendarDay("2026-03-01")).adding(days: -1).description == "2026-02-28")
    }

    @Test func addingDaysIgnoresDSTTransitions() throws {
        // 2026-11-01 is a 25-hour day in the US; day arithmetic must not drift.
        let day = try #require(CalendarDay("2026-10-31"))
        #expect(day.adding(days: 2).description == "2026-11-02")
    }

    @Test func dayContainingInstantDependsOnTimeZone() throws {
        let instant = try Date("2026-10-28T03:00:00Z", strategy: .iso8601)
        #expect(CalendarDay(containing: instant, in: .gmt).description == "2026-10-28")
        #expect(CalendarDay(containing: instant, in: try #require(TimeZone(identifier: "America/Los_Angeles"))).description == "2026-10-27")
    }

    @Test func ordering() throws {
        let a = try #require(CalendarDay("2026-10-28"))
        let b = try #require(CalendarDay("2026-11-01"))
        #expect(a < b)
        #expect(!(b < a))
    }
}

struct WallClockTimeTests {
    @Test(arguments: ["00:00", "07:30", "23:59"])
    func parsesValidTimes(_ string: String) throws {
        #expect(try #require(WallClockTime(string)).description == string)
    }

    @Test(arguments: ["24:00", "12:60", "7:30", "07:3", "0730", "07:30:00", "", "ab:cd"])
    func rejectsInvalidTimes(_ string: String) {
        #expect(WallClockTime(string) == nil)
    }
}
