import Domain
import Foundation
import Persistence
import Testing

private func task(
    _ id: String, day: String = "2026-10-28", time: String = "07:30", workOrder: String = "wo_1", sequence: Int = 1,
    kind: TaskKind = .pick, status: TaskStatus = .pending, allowed: Set<TaskActionKind> = [.complete, .reschedule]
) -> WorkTask {
    WorkTask(
        id: id, workOrder: WorkOrder(id: workOrder, reference: "WO-\(workOrder)", customer: "Halcyon Coffee"),
        kind: kind, sequence: sequence, status: status, day: CalendarDay(day)!, time: WallClockTime(time)!,
        allowedActions: allowed, createdAt: Date(timeIntervalSince1970: 1_000)
    )
}

private let oct28 = CalendarDay("2026-10-28")!
private let oct29 = CalendarDay("2026-10-29")!

struct SwiftDataTaskStoreTests {
    let store: SwiftDataTaskStore

    init() throws { store = try SwiftDataTaskStore.make(inMemory: true) }

    @Test func roundTripsEveryField() async throws {
        let original = task("t1", kind: .unknown("returns"), status: .unknown("blocked"), allowed: [.reschedule, .unknown("escalate")])
        try await store.upsert([original])
        #expect(try await store.task(id: "t1") == original)
    }

    @Test func missingTaskIsNil() async throws {
        #expect(try await store.task(id: "nope") == nil)
    }

    @Test func dayQueryReturnsOnlyThatDaySortedByTime() async throws {
        try await store.upsert([task("late", time: "16:00"), task("early", time: "07:00"), task("tomorrow", day: "2026-10-29")])
        #expect(try await store.tasks(on: oct28).map(\.id) == ["early", "late"])
    }

    @Test func upsertUpdatesInPlaceAndMovesBetweenDays() async throws {
        try await store.upsert([task("t1")])
        try await store.upsert([task("t1", day: "2026-10-29", status: .done, allowed: [])])

        #expect(try await store.tasks(on: oct28).isEmpty)
        let moved = try #require(try await store.task(id: "t1"))
        #expect(moved.day == oct29)
        #expect(moved.status == .done)
    }

    @Test func replaceDayEvictsTasksTheServerNoLongerReturns() async throws {
        try await store.upsert([task("stays"), task("rescheduled_away"), task("other_day", day: "2026-10-29")])
        try await store.replace(day: oct28, with: [task("stays"), task("new_today")], syncedAt: Date(timeIntervalSince1970: 50))

        #expect(Set(try await store.tasks(on: oct28).map(\.id)) == ["stays", "new_today"])
        #expect(try await store.task(id: "rescheduled_away") == nil)
        #expect(try await store.tasks(on: oct29).map(\.id) == ["other_day"])
    }

    @Test func replaceDayWithNothingEmptiesIt() async throws {
        try await store.upsert([task("t1")])
        try await store.replace(day: oct28, with: [], syncedAt: Date(timeIntervalSince1970: 50))
        #expect(try await store.tasks(on: oct28).isEmpty)
        #expect(try await store.lastSynced(day: oct28) == Date(timeIntervalSince1970: 50))
    }

    @Test func lastSyncedIsPerDayAndOverwritten() async throws {
        #expect(try await store.lastSynced(day: oct28) == nil)
        try await store.replace(day: oct28, with: [], syncedAt: Date(timeIntervalSince1970: 10))
        try await store.replace(day: oct28, with: [], syncedAt: Date(timeIntervalSince1970: 20))
        #expect(try await store.lastSynced(day: oct28) == Date(timeIntervalSince1970: 20))
        #expect(try await store.lastSynced(day: oct29) == nil)
    }

    @Test func workOrderQueryIsSortedBySequenceAcrossDays() async throws {
        try await store.upsert([
            task("ship", day: "2026-10-29", sequence: 3, kind: .ship),
            task("pick", sequence: 1),
            task("pack", day: "2026-10-27", sequence: 2, kind: .pack),
            task("other", workOrder: "wo_2"),
        ])
        #expect(try await store.tasks(inWorkOrder: "wo_1").map(\.id) == ["pick", "pack", "ship"])
    }

    @Test func deleteRemovesOnlyGivenIDs() async throws {
        try await store.upsert([task("a"), task("b"), task("c")])
        try await store.delete(ids: ["a", "c"])
        #expect(try await store.tasks(on: oct28).map(\.id) == ["b"])
    }

    @Test func deleteAllClearsTasksAndSyncTimes() async throws {
        try await store.upsert([task("a"), task("b", day: "2026-10-29")])
        try await store.replace(day: oct28, with: [task("a")], syncedAt: Date(timeIntervalSince1970: 5))
        try await store.deleteAll()

        #expect(try await store.tasks(on: oct28).isEmpty)
        #expect(try await store.tasks(on: oct29).isEmpty)
        #expect(try await store.lastSynced(day: oct28) == nil)
    }

    @Test func persistsAcrossStoreInstancesOnDisk() async throws {
        // Offline reads after a relaunch depend on this.
        let url = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SwiftDataTaskStore.make(url: url).upsert([task("t1")])
        #expect(try await SwiftDataTaskStore.make(url: url).task(id: "t1")?.id == "t1")
    }
}
