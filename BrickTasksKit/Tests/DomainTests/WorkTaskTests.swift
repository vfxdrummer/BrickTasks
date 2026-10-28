import Domain
import Foundation
import Testing

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func makeTask(
    day: String = "2026-10-28",
    time: String = "07:30",
    status: TaskStatus = .pending,
    allowed: Set<TaskActionKind> = [.complete, .reschedule]
) -> WorkTask {
    WorkTask(
        id: "task_1",
        workOrder: WorkOrder(id: "wo_1", reference: "WO-1", customer: "Halcyon Coffee"),
        kind: .pick, sequence: 1, status: status,
        day: CalendarDay(day)!, time: WallClockTime(time)!,
        allowedActions: allowed, createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// `local` is wall-clock time in Los Angeles.
private func clock(_ local: String) -> FixedWarehouseClock {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = losAngeles
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return FixedWarehouseClock(now: formatter.date(from: local)!, timeZone: losAngeles)
}

struct DueDateTests {
    @Test func readsDayAndTimeAsWarehouseWallClock() throws {
        // PDT is UTC-7 on 2026-10-28.
        #expect(makeTask().dueDate(in: losAngeles) == (try Date("2026-10-28T14:30:00Z", strategy: .iso8601)))
    }

    @Test func sameWallClockIsADifferentInstantInAnotherZone() {
        let task = makeTask()
        #expect(task.dueDate(in: losAngeles) != task.dueDate(in: .gmt))
    }

    @Test func timeSkippedBySpringForwardResolvesToALaterValidInstant() throws {
        // 02:30 does not exist in LA on 2026-03-08.
        let due = makeTask(day: "2026-03-08", time: "02:30").dueDate(in: losAngeles)
        #expect(due > (try Date("2026-03-08T09:59:00Z", strategy: .iso8601))) // 01:59 PST
        #expect(CalendarDay(containing: due, in: losAngeles).description == "2026-03-08")
    }
}

struct OverdueTests {
    @Test func notOverdueOneMinuteBeforeDue() {
        #expect(!makeTask().isOverdue(at: clock("2026-10-28 07:29:00")))
    }

    @Test func notOverdueExactlyAtDueTime() {
        #expect(!makeTask().isOverdue(at: clock("2026-10-28 07:30:00")))
    }

    @Test func overdueOneMinuteAfterDue() {
        #expect(makeTask().isOverdue(at: clock("2026-10-28 07:31:00")))
    }

    @Test func pastDayIsOverdueAllDay() {
        #expect(makeTask(day: "2026-10-27", time: "23:59").isOverdue(at: clock("2026-10-28 00:00:30")))
    }

    @Test func midnightTaskIsOverdueRightAfterMidnight() {
        // The sandbox really does generate 00:00 tasks.
        #expect(makeTask(time: "00:00").isOverdue(at: clock("2026-10-28 00:01:00")))
    }

    @Test func futureDayIsNotOverdue() {
        #expect(!makeTask(day: "2026-10-29", time: "00:00").isOverdue(at: clock("2026-10-28 23:59:00")))
    }

    @Test func doneTaskIsNeverOverdue() {
        #expect(!makeTask(status: .done, allowed: []).isOverdue(at: clock("2026-11-30 00:00:00")))
    }

    @Test func unknownStatusCountsAsNotDone() {
        #expect(makeTask(status: .unknown("blocked")).isOverdue(at: clock("2026-10-28 08:00:00")))
    }
}

struct AllowedActionTests {
    @Test func gatesOnServerAllowedActions() {
        let next = makeTask(allowed: [.complete, .reschedule])
        #expect(next.canComplete && next.canReschedule)

        let blocked = makeTask(allowed: [.reschedule])
        #expect(!blocked.canComplete && blocked.canReschedule)

        let done = makeTask(status: .done, allowed: [])
        #expect(!done.canComplete && !done.canReschedule)
    }

    @Test func unknownActionsDontEnableAnything() {
        let task = makeTask(allowed: [.unknown("archive")])
        #expect(!task.canComplete && !task.canReschedule)
    }
}

struct WarehouseClockTests {
    @Test func todayIsTheCalendarDayInTheWarehouseZone() throws {
        let instant = try Date("2026-10-29T05:00:00Z", strategy: .iso8601) // 22:00 on 10-28 in LA
        #expect(FixedWarehouseClock(now: instant, timeZone: losAngeles).today.description == "2026-10-28")
        #expect(FixedWarehouseClock(now: instant, timeZone: .gmt).today.description == "2026-10-29")
    }
}
