import Domain
import Foundation
import TaskSimulator
import Testing

private let today = CalendarDay("2026-10-28")!

private func chain() -> [WorkTask] {
    let wo = WorkOrder(id: "wo_1", reference: "WO-1", customer: "Halcyon Coffee")
    return [TaskKind.pick, .pack, .ship].enumerated().map { index, kind in
        WorkTask(id: "t\(index + 1)", workOrder: wo, kind: kind, sequence: index + 1, status: .pending,
                 day: today, time: WallClockTime("0\(7 + index):00")!, allowedActions: [], createdAt: .distantPast)
    }
}

/// The simulator stands in for the real server in repository tests and UI tests, so it must
/// follow the same rules the sandbox was observed to follow.
struct SimulatedTaskServerTests {
    @Test func derivesAllowedActionsFromSequence() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        let tasks = try await api.tasks(matching: TaskQuery(workOrderID: "wo_1"))
        #expect(tasks.map(\.allowedActions) == [[.complete, .reschedule], [.reschedule], [.reschedule]])
    }

    @Test func completingUnlocksTheNextStep() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        _ = try await api.complete(taskID: "t1")
        #expect(try await api.task(id: "t1").allowedActions.isEmpty)
        #expect(try await api.task(id: "t2").allowedActions == [.complete, .reschedule])
    }

    @Test func refusesOutOfOrderCompleteLikeTheServer() async {
        let api = SimulatedTaskServer(tasks: chain())
        await #expect(throws: RemoteDataSourceError.actionNotAllowed(message: "pack cannot be completed until pick is done")) {
            try await api.complete(taskID: "t2")
        }
    }

    @Test func refusesRepeatCompleteAndRescheduleOfDoneTask() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        _ = try await api.complete(taskID: "t1")
        await #expect(throws: RemoteDataSourceError.actionNotAllowed(message: "pick is already done")) { try await api.complete(taskID: "t1") }
        await #expect(throws: RemoteDataSourceError.actionNotAllowed(message: "pick is already done")) {
            try await api.reschedule(taskID: "t1", to: today.adding(days: 1))
        }
    }

    @Test func rescheduleMovesDayKeepsTime() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        let receipt = try await api.reschedule(taskID: "t3", to: today.adding(days: -2))
        let moved = try await api.task(id: "t3")
        #expect(moved.day == today.adding(days: -2))
        #expect(moved.time == WallClockTime("09:00"))
        #expect(receipt.day == today.adding(days: -2))
    }

    @Test func filtersByDayWorkOrderAndStatus() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        _ = try await api.complete(taskID: "t1")
        _ = try await api.reschedule(taskID: "t3", to: today.adding(days: 1))
        #expect(try await api.tasks(matching: TaskQuery(day: today)).map(\.id) == ["t1", "t2"])
        #expect(try await api.tasks(matching: TaskQuery(status: .pending)).map(\.id) == ["t2", "t3"])
    }

    @Test func unknownTaskIsNotFound() async {
        let api = SimulatedTaskServer(tasks: chain())
        await #expect(throws: RemoteDataSourceError.notFound(message: "No such task")) { try await api.task(id: "nope") }
        await #expect(throws: RemoteDataSourceError.notFound(message: "No such task")) { try await api.complete(taskID: "nope") }
    }

    @Test func failureBeforeDoesNotApply() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        await api.fail(.complete, with: .before(.connectionInterrupted))
        await #expect(throws: RemoteDataSourceError.connectionInterrupted) { try await api.complete(taskID: "t1") }
        #expect(await api.serverTask(id: "t1")?.status == .pending)
    }

    @Test func failureAfterAppliesThenThrows() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        await api.fail(.complete, with: .after(.connectionInterrupted))
        await #expect(throws: RemoteDataSourceError.connectionInterrupted) { try await api.complete(taskID: "t1") }
        #expect(await api.serverTask(id: "t1")?.status == .done)
    }

    @Test func failuresAreConsumedInOrder() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        await api.fail(.get, with: .before(.rateLimited(retryAfter: 1)))
        await #expect(throws: RemoteDataSourceError.rateLimited(retryAfter: 1)) { try await api.task(id: "t1") }
        #expect(try await api.task(id: "t1").id == "t1")
    }

    @Test func offlineFailsEverythingUntilBackOnline() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        await api.setOffline(true)
        await #expect(throws: RemoteDataSourceError.notConnected) { try await api.tasks(matching: TaskQuery()) }
        await api.setOffline(false)
        #expect(try await api.tasks(matching: TaskQuery()).count == 3)
    }

    @Test func officeEditsRecomputeAllowedActions() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        let pick = try await api.task(id: "t1")
        await api.officeEdit(pick.with(status: .done, day: pick.day, allowedActions: []))
        #expect(try await api.task(id: "t2").canComplete)
    }

    @Test func resetRestoresStartingState() async throws {
        let api = SimulatedTaskServer(tasks: chain())
        _ = try await api.complete(taskID: "t1")
        _ = try await api.reschedule(taskID: "t3", to: today.adding(days: 4))
        try await api.resetSandbox()

        #expect(try await api.task(id: "t1").status == .pending)
        #expect(try await api.task(id: "t3").day == today)
    }

    @Test func sampleDataIsValidAndCentredOnToday() async throws {
        let api = SimulatedTaskServer(tasks: SampleData.workOrders(around: today))
        let todays = try await api.tasks(matching: TaskQuery(day: today))
        #expect(todays.count == 9)
        #expect(todays.contains { $0.isDone })
        #expect(todays.contains { $0.canComplete })
        #expect(todays.contains { !$0.canComplete && !$0.isDone })
    }
}
