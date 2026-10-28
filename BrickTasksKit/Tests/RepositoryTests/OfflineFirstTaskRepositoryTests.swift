import Domain
import Foundation
import Persistence
import Repository
import TaskSimulator
import Testing

private let today = CalendarDay("2026-10-28")!
private let now = Date(timeIntervalSince1970: 1_793_200_000)

private func chain(_ wo: String = "wo_1", day: CalendarDay = today) -> [WorkTask] {
    let workOrder = WorkOrder(id: wo, reference: "WO-\(wo)", customer: "Halcyon Coffee")
    return [TaskKind.pick, .pack, .ship].enumerated().map { index, kind in
        WorkTask(id: "\(wo)_\(index + 1)", workOrder: workOrder, kind: kind, sequence: index + 1, status: .pending,
                 day: day, time: WallClockTime("0\(7 + index):00")!, allowedActions: [], createdAt: .distantPast)
    }
}

/// Real in-memory SwiftData store + simulated server: tests observe what the operator would see.
struct Harness {
    let server: SimulatedTaskServer
    let store: SwiftDataTaskStore
    let repository: OfflineFirstTaskRepository

    init(tasks: [WorkTask] = chain(), resettable: Bool = true) throws {
        server = SimulatedTaskServer(tasks: tasks)
        store = try SwiftDataTaskStore.make(inMemory: true)
        repository = OfflineFirstTaskRepository(
            remote: server, local: store, clock: FixedWarehouseClock(now: now, timeZone: .gmt), sandbox: resettable ? server : nil
        )
    }
}

struct ReadTests {
    @Test func cacheIsEmptyBeforeFirstRefresh() async throws {
        let h = try Harness()
        let snapshot = await h.repository.cachedDay(today)
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.lastSyncedAt == nil)
    }

    @Test func refreshFillsCacheAndStampsSyncTime() async throws {
        let h = try Harness()
        let snapshot = try await h.repository.refreshDay(today)
        #expect(snapshot.tasks.map(\.id) == ["wo_1_1", "wo_1_2", "wo_1_3"])
        #expect(snapshot.lastSyncedAt == now)
        #expect(await h.repository.cachedDay(today) == snapshot)
    }

    @Test func offlineRefreshFailsButCacheStillServes() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.setOffline(true)

        await #expect(throws: RepositoryError.offline) { try await h.repository.refreshDay(today) }
        #expect(await h.repository.cachedDay(today).tasks.count == 3)
        #expect(await h.repository.cachedTask(id: "wo_1_2")?.kind == .pack)
    }

    @Test func refreshDropsTasksRescheduledAwayByTheOffice() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        let ship = try #require(await h.server.serverTask(id: "wo_1_3"))
        await h.server.officeEdit(ship.with(status: .pending, day: today.adding(days: 1), allowedActions: []))

        let snapshot = try await h.repository.refreshDay(today)
        #expect(snapshot.tasks.map(\.id) == ["wo_1_1", "wo_1_2"])
    }

    @Test func refreshPicksUpOfficeCompletions() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        _ = try await h.server.complete(taskID: "wo_1_1") // office staff, not us

        let snapshot = try await h.repository.refreshDay(today)
        #expect(snapshot.tasks.first?.isDone == true)
        #expect(snapshot.tasks[1].canComplete)
    }

    @Test func expiredSandboxIsListUnavailable() async throws {
        let h = try Harness()
        await h.server.fail(.list, with: .before(.notFound(message: "Not found")))
        await #expect(throws: RepositoryError.listUnavailable) { try await h.repository.refreshDay(today) }
    }

    @Test(arguments: [
        (RemoteDataSourceError.rateLimited(retryAfter: 1), RepositoryError.busy),
        (.connectionInterrupted, .offline),
        (.server(status: 500, message: nil), .unexpected("The server had a problem (500).")),
    ])
    func refreshErrorsMapToOperatorMeaning(_ pair: (RemoteDataSourceError, RepositoryError)) async throws {
        let h = try Harness()
        await h.server.fail(.list, with: .before(pair.0))
        await #expect(throws: pair.1) { try await h.repository.refreshDay(today) }
    }

    @Test func refreshWorkOrderFetchesWholeChainAcrossDays() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        let ship = try #require(await h.server.serverTask(id: "wo_1_3"))
        await h.server.officeEdit(ship.with(status: .pending, day: today.adding(days: 3), allowedActions: []))

        try await h.repository.refreshWorkOrder(containing: "wo_1_1")
        let chain = await h.repository.cachedWorkOrder(id: "wo_1")
        #expect(chain.map(\.id) == ["wo_1_1", "wo_1_2", "wo_1_3"])
        #expect(chain.last?.day == today.adding(days: 3))
    }

    @Test func refreshWorkOrderWorksForUncachedTask() async throws {
        let h = try Harness()
        try await h.repository.refreshWorkOrder(containing: "wo_1_2")
        #expect(await h.repository.cachedWorkOrder(id: "wo_1").count == 3)
    }

    @Test func taskDeletedOnServerIsRemovedLocally() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.officeDelete(id: "wo_1_2")

        await #expect(throws: RepositoryError.taskNotFound) { try await h.repository.refreshWorkOrder(containing: "wo_1_2") }
        #expect(await h.repository.cachedTask(id: "wo_1_2") == nil)
        #expect(await h.repository.cachedTask(id: "wo_1_1") != nil)
    }
}

struct CompleteTests {
    @Test func completeUpdatesTaskAndUnlocksNextStepLocally() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)

        #expect(try await h.repository.complete(taskID: "wo_1_1") == .applied)
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == true)
        #expect(await h.repository.cachedTask(id: "wo_1_2")?.canComplete == true)
    }

    @Test func offlineCompleteChangesNothingAndIsNotQueued() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.setOffline(true)

        await #expect(throws: RepositoryError.offline) { try await h.repository.complete(taskID: "wo_1_1") }
        await h.server.setOffline(false)
        #expect(await h.server.serverTask(id: "wo_1_1")?.status == .pending)
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == false)
    }

    @Test func lostResponseButLandedIsApplied() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.complete, with: .after(.connectionInterrupted))

        #expect(try await h.repository.complete(taskID: "wo_1_1") == .applied)
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == true)
        let completes = await h.server.calls.filter { if case .complete = $0 { true } else { false } }
        #expect(completes.count == 1) // never retried
    }

    @Test func lostRequestThatDidNotLandIsNotApplied() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.complete, with: .before(.connectionInterrupted))

        await #expect(throws: RepositoryError.notApplied) { try await h.repository.complete(taskID: "wo_1_1") }
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == false)
    }

    @Test func lostResponseAndCannotConfirmIsOutcomeUnknown() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.complete, with: .after(.connectionInterrupted))
        await h.server.fail(.list, with: .before(.notConnected))

        await #expect(throws: RepositoryError.outcomeUnknown) { try await h.repository.complete(taskID: "wo_1_1") }
    }

    @Test func conflictBecauseOfficeAlreadyCompletedIsAlreadyApplied() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        _ = try await h.server.complete(taskID: "wo_1_1") // office got there first

        #expect(try await h.repository.complete(taskID: "wo_1_1") == .alreadyApplied)
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == true)
    }

    @Test func conflictBecauseEarlierStepUndoneIsRejectedWithFreshState() async throws {
        let h = try Harness()
        // Our cache is stale: it thinks pack is completable.
        _ = try await h.server.complete(taskID: "wo_1_1")
        _ = try await h.repository.refreshDay(today)
        let pick = try #require(await h.server.serverTask(id: "wo_1_1"))
        await h.server.officeEdit(pick.with(status: .pending, day: pick.day, allowedActions: []))

        await #expect(throws: RepositoryError.rejected(message: "pack cannot be completed until pick is done")) {
            try await h.repository.complete(taskID: "wo_1_2")
        }
        #expect(await h.repository.cachedTask(id: "wo_1_2")?.canComplete == false)
    }

    @Test func completingDeletedTaskRemovesIt() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.officeDelete(id: "wo_1_1")

        await #expect(throws: RepositoryError.taskNotFound) { try await h.repository.complete(taskID: "wo_1_1") }
        #expect(await h.repository.cachedTask(id: "wo_1_1") == nil)
    }

    @Test func rateLimitedActionIsBusyAndNotRetried() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.complete, with: .before(.rateLimited(retryAfter: 1)))

        await #expect(throws: RepositoryError.busy) { try await h.repository.complete(taskID: "wo_1_1") }
        #expect(await h.server.serverTask(id: "wo_1_1")?.status == .pending)
    }

    @Test func refetchFailureAfterSuccessStillShowsTheChange() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.list, with: .before(.notConnected))

        #expect(try await h.repository.complete(taskID: "wo_1_1") == .applied)
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == true)
    }
}

struct RescheduleTests {
    @Test func rescheduleMovesTaskBetweenCachedDays() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        let tomorrow = today.adding(days: 1)

        #expect(try await h.repository.reschedule(taskID: "wo_1_3", to: tomorrow) == .applied)
        #expect(await h.repository.cachedDay(today).tasks.map(\.id) == ["wo_1_1", "wo_1_2"])
        #expect(await h.repository.cachedDay(tomorrow).tasks.map(\.id) == ["wo_1_3"])
    }

    @Test func lostResponseButLandedIsApplied() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.reschedule, with: .after(.connectionInterrupted))

        #expect(try await h.repository.reschedule(taskID: "wo_1_2", to: today.adding(days: 2)) == .applied)
        #expect(await h.repository.cachedTask(id: "wo_1_2")?.day == today.adding(days: 2))
    }

    @Test func reschedulingADoneTaskIsRejected() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        _ = try await h.server.complete(taskID: "wo_1_1")

        await #expect(throws: RepositoryError.rejected(message: "pick is already done")) {
            try await h.repository.reschedule(taskID: "wo_1_1", to: today.adding(days: 1))
        }
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.isDone == true)
    }

    @Test func refetchFailureAfterSuccessPatchesDayLocally() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.fail(.list, with: .before(.notConnected))

        _ = try await h.repository.reschedule(taskID: "wo_1_1", to: today.adding(days: 1))
        #expect(await h.repository.cachedTask(id: "wo_1_1")?.day == today.adding(days: 1))
    }
}

struct ChangeFeedTests {
    @Test func notifiesListenersWhenTheCacheChanges() async throws {
        let h = try Harness()
        var iterator = h.repository.changes().makeAsyncIterator()
        _ = try await h.repository.refreshDay(today)
        #expect(await iterator.next() != nil)
    }

    @Test func everyListenerIsNotified() async throws {
        let h = try Harness()
        var first = h.repository.changes().makeAsyncIterator()
        var second = h.repository.changes().makeAsyncIterator()
        _ = try await h.repository.complete(taskID: "wo_1_1")
        #expect(await first.next() != nil)
        #expect(await second.next() != nil)
    }
}

struct SandboxResetTests {
    @Test func resetRestoresServerAndClearsEveryCachedDay() async throws {
        let h = try Harness(tasks: chain() + chain("wo_2", day: today.adding(days: 1)))
        _ = try await h.repository.refreshDay(today)
        _ = try await h.repository.refreshDay(today.adding(days: 1))
        _ = try await h.repository.complete(taskID: "wo_1_1")

        try await h.repository.resetSandbox()

        #expect(await h.server.serverTask(id: "wo_1_1")?.status == .pending)
        #expect(await h.repository.cachedDay(today) == DaySnapshot(day: today, tasks: [], lastSyncedAt: nil))
        #expect(await h.repository.cachedDay(today.adding(days: 1)).tasks.isEmpty)
    }

    @Test func resetOfflineKeepsTheCache() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.setOffline(true)

        await #expect(throws: RepositoryError.offline) { try await h.repository.resetSandbox() }
        #expect(await h.repository.cachedDay(today).tasks.count == 3)
    }

    @Test func resetIsUnavailableWithoutASandbox() async throws {
        let h = try Harness(resettable: false)
        #expect(!h.repository.canResetSandbox)
        await #expect(throws: RepositoryError.self) { try await h.repository.resetSandbox() }
        #expect(await h.server.calls.isEmpty)
    }
}
