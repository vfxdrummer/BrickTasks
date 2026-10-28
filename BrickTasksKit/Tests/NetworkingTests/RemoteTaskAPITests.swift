import Domain
import Foundation
@testable import Networking
import Testing

private let today = TaskQuery(day: CalendarDay("2026-10-28"))

struct PaginationTests {
    @Test func singlePageMakesOneRequestAtMaxPageSize() async throws {
        let endpoints = FakeTaskEndpoints(list: [.success(TaskPage(items: makeTasks(0..<17), total: 17, offset: 0))])
        let tasks = try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: today)

        #expect(tasks.map(\.id) == makeTasks(0..<17).map(\.id))
        #expect(await endpoints.calls == [.list(today, offset: 0, limit: 50)])
    }

    @Test func followsPagesUntilTotalIsReached() async throws {
        let endpoints = FakeTaskEndpoints(list: [
            .success(TaskPage(items: makeTasks(0..<50), total: 120, offset: 0)),
            .success(TaskPage(items: makeTasks(50..<100), total: 120, offset: 50)),
            .success(TaskPage(items: makeTasks(100..<120), total: 120, offset: 100)),
        ])
        let tasks = try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: TaskQuery())

        #expect(tasks.count == 120)
        #expect(await endpoints.calls == [
            .list(TaskQuery(), offset: 0, limit: 50),
            .list(TaskQuery(), offset: 50, limit: 50),
            .list(TaskQuery(), offset: 100, limit: 50),
        ])
    }

    @Test func dropsDuplicatesWhenOffsetsShiftBetweenPages() async throws {
        // Someone rescheduled a task onto an earlier day between our requests, so page 2 repeats task_49.
        let endpoints = FakeTaskEndpoints(list: [
            .success(TaskPage(items: makeTasks(0..<50), total: 60, offset: 0)),
            .success(TaskPage(items: makeTasks(49..<60), total: 60, offset: 50)),
        ])
        let tasks = try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: TaskQuery())

        #expect(tasks.map(\.id) == makeTasks(0..<60).map(\.id))
    }

    @Test func advancesByItemsReturnedNotByPageSize() async throws {
        let endpoints = FakeTaskEndpoints(list: [
            .success(TaskPage(items: makeTasks(0..<30), total: 40, offset: 0)),
            .success(TaskPage(items: makeTasks(30..<40), total: 40, offset: 30)),
        ])
        _ = try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: TaskQuery())

        #expect(await endpoints.calls.last == .list(TaskQuery(), offset: 30, limit: 50))
    }

    @Test func stopsOnEmptyPageEvenIfTotalClaimsMore() async throws {
        // Tasks were rescheduled away mid-paging, so total is stale.
        let endpoints = FakeTaskEndpoints(list: [
            .success(TaskPage(items: makeTasks(0..<50), total: 55, offset: 0)),
            .success(TaskPage(items: [], total: 50, offset: 50)),
        ])
        let tasks = try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: TaskQuery())

        #expect(tasks.count == 50)
    }

    @Test func emptyDayReturnsNoTasks() async throws {
        let endpoints = FakeTaskEndpoints(list: [.success(TaskPage(items: [], total: 0, offset: 0))])
        #expect(try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: today).isEmpty)
    }

    @Test func givesUpOnAServerThatNeverFinishes() async {
        let endless = (0..<RemoteTaskAPI.maxPages).map { page in
            Result<TaskPage, APIError>.success(TaskPage(items: [makeTask("task_\(page)")], total: .max, offset: page))
        }
        let endpoints = FakeTaskEndpoints(list: endless)

        await #expect(throws: APIError.self) {
            try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: TaskQuery())
        }
        #expect(await endpoints.calls.count == RemoteTaskAPI.maxPages)
    }

    @Test func errorOnALaterPageFailsTheWholeFetch() async {
        // A partial day would look complete to the operator.
        let endpoints = FakeTaskEndpoints(list: [
            .success(TaskPage(items: makeTasks(0..<50), total: 60, offset: 0)),
            .failure(.connectionInterrupted),
        ])
        await #expect(throws: APIError.connectionInterrupted) {
            try await RemoteTaskAPI(endpoints: endpoints).tasks(matching: TaskQuery())
        }
    }
}

struct ReadRetryTests {
    @Test func retriesOnceAfterRetryAfter() async throws {
        let endpoints = FakeTaskEndpoints(get: [.failure(.rateLimited(retryAfter: 1)), .success(makeTask("task_1"))])
        let sleeper = RecordingSleeper()

        let task = try await RemoteTaskAPI(endpoints: endpoints, sleeper: sleeper).task(id: "task_1")

        #expect(task.id == "task_1")
        #expect(await sleeper.sleeps == [1])
        #expect(await endpoints.calls == [.get("task_1"), .get("task_1")])
    }

    @Test func defaultsToOneSecondWithoutRetryAfter() async throws {
        let endpoints = FakeTaskEndpoints(get: [.failure(.rateLimited(retryAfter: nil)), .success(makeTask("task_1"))])
        let sleeper = RecordingSleeper()

        _ = try await RemoteTaskAPI(endpoints: endpoints, sleeper: sleeper).task(id: "task_1")

        #expect(await sleeper.sleeps == [1])
    }

    @Test func retriesOnlyOnce() async {
        let endpoints = FakeTaskEndpoints(get: [.failure(.rateLimited(retryAfter: 1)), .failure(.rateLimited(retryAfter: 1))])

        await #expect(throws: APIError.rateLimited(retryAfter: 1)) {
            try await RemoteTaskAPI(endpoints: endpoints, sleeper: RecordingSleeper()).task(id: "task_1")
        }
        #expect(await endpoints.calls.count == 2)
    }

    @Test func doesNotWaitForALongRetryAfter() async {
        let endpoints = FakeTaskEndpoints(get: [.failure(.rateLimited(retryAfter: 30))])
        let sleeper = RecordingSleeper()

        await #expect(throws: APIError.rateLimited(retryAfter: 30)) {
            try await RemoteTaskAPI(endpoints: endpoints, sleeper: sleeper).task(id: "task_1")
        }
        #expect(await sleeper.sleeps.isEmpty)
    }

    @Test func retriesEachPageIndependently() async throws {
        let endpoints = FakeTaskEndpoints(list: [
            .success(TaskPage(items: makeTasks(0..<50), total: 60, offset: 0)),
            .failure(.rateLimited(retryAfter: 1)),
            .success(TaskPage(items: makeTasks(50..<60), total: 60, offset: 50)),
        ])
        let tasks = try await RemoteTaskAPI(endpoints: endpoints, sleeper: RecordingSleeper()).tasks(matching: TaskQuery())

        #expect(tasks.count == 60)
    }

    @Test(arguments: [APIError.notConnected, .connectionInterrupted, .notFound(message: "No such task"), .server(status: 500, message: nil)])
    func doesNotRetryOtherErrors(_ error: APIError) async {
        let endpoints = FakeTaskEndpoints(get: [.failure(error)])
        await #expect(throws: error) {
            try await RemoteTaskAPI(endpoints: endpoints, sleeper: RecordingSleeper()).task(id: "task_1")
        }
        #expect(await endpoints.calls.count == 1)
    }
}

struct ActionTests {
    @Test func completeSendsCompleteAction() async throws {
        let endpoints = FakeTaskEndpoints(action: [.success(receipt)])
        #expect(try await RemoteTaskAPI(endpoints: endpoints).complete(taskID: "task_1") == receipt)
        #expect(await endpoints.calls == [.action(.complete(taskID: "task_1"))])
    }

    @Test func rescheduleSendsTheDay() async throws {
        let endpoints = FakeTaskEndpoints(action: [.success(receipt)])
        let day = try #require(CalendarDay("2026-10-30"))
        _ = try await RemoteTaskAPI(endpoints: endpoints).reschedule(taskID: "task_1", to: day)
        #expect(await endpoints.calls == [.action(.reschedule(taskID: "task_1", day: day))])
    }

    @Test(arguments: [APIError.rateLimited(retryAfter: 1), .connectionInterrupted, .actionNotAllowed(message: "pick is already done")])
    func actionsAreNeverRetried(_ error: APIError) async {
        // No idempotency key: a retry after a lost response could double-apply or 409.
        let endpoints = FakeTaskEndpoints(action: [.failure(error), .success(receipt)])
        let sleeper = RecordingSleeper()

        await #expect(throws: error) {
            try await RemoteTaskAPI(endpoints: endpoints, sleeper: sleeper).complete(taskID: "task_1")
        }
        #expect(await endpoints.calls.count == 1)
        #expect(await sleeper.sleeps.isEmpty)
    }
}
