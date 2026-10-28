public import Domain
public import Foundation

/// `TaskRepository` that serves the local store and refreshes it from the server.
///
/// Actions are online-only and never queued or blindly retried: the API has no idempotency key.
/// When an action's outcome is unclear (lost response, or a 409 that may be our own earlier
/// attempt), the work order is refetched and the server's state decides what happened.
public final class OfflineFirstTaskRepository: TaskRepository {
    private let api: any TaskAPI
    private let store: any TaskStore
    private let clock: any WarehouseClock
    private let sandbox: (any SandboxReset)?
    private let feed = ChangeFeed()

    public init(api: any TaskAPI, store: any TaskStore, clock: any WarehouseClock, sandbox: (any SandboxReset)? = nil) {
        self.api = api
        self.store = store
        self.clock = clock
        self.sandbox = sandbox
    }

    public var canResetSandbox: Bool { sandbox != nil }

    public func resetSandbox() async throws(RepositoryError) {
        guard let sandbox else { throw .unexpected("Reset isn't available in this build.") }
        do {
            try await sandbox.resetSandbox()
        } catch .notFound {
            throw .listUnavailable
        } catch {
            throw Self.map(error)
        }
        // Ids survive a reset but every date and status changes, so nothing cached is trustworthy.
        try await write { try await store.deleteAll() }
    }

    public func changes() -> AsyncStream<Void> { feed.stream() }

    // MARK: Reads

    /// Store failures fall back to empty: the screen then offers a refresh instead of a dead end.
    public func cachedDay(_ day: CalendarDay) async -> DaySnapshot {
        DaySnapshot(
            day: day,
            tasks: (try? await store.tasks(on: day)) ?? [],
            lastSyncedAt: try? await store.lastSynced(day: day)
        )
    }

    public func refreshDay(_ day: CalendarDay) async throws(RepositoryError) -> DaySnapshot {
        let tasks: [WorkTask]
        do {
            tasks = try await api.tasks(matching: TaskQuery(day: day))
        } catch .notFound {
            throw .listUnavailable
        } catch {
            throw Self.map(error)
        }
        try await write { try await store.replace(day: day, with: tasks, syncedAt: clock.now) }
        return await cachedDay(day)
    }

    public func cachedTask(id: String) async -> WorkTask? {
        try? await store.task(id: id)
    }

    public func cachedWorkOrder(id: String) async -> [WorkTask] {
        (try? await store.tasks(inWorkOrder: id)) ?? []
    }

    public func refreshWorkOrder(containing taskID: String) async throws(RepositoryError) {
        let workOrderID: String
        if let cached = await cachedTask(id: taskID) {
            workOrderID = cached.workOrder.id
        } else {
            do {
                workOrderID = try await api.task(id: taskID).workOrder.id
            } catch .notFound {
                throw .taskNotFound
            } catch {
                throw Self.map(error)
            }
        }

        let fresh: [WorkTask]
        do {
            fresh = try await api.tasks(matching: TaskQuery(workOrderID: workOrderID))
        } catch {
            throw Self.map(error)
        }
        let cachedIDs = Set(await cachedWorkOrder(id: workOrderID).map(\.id))
        let gone = cachedIDs.subtracting(fresh.map(\.id))
        try await write {
            try await store.delete(ids: gone)
            try await store.upsert(fresh)
        }
        if !fresh.contains(where: { $0.id == taskID }) { throw .taskNotFound }
    }

    // MARK: Actions

    public func complete(taskID: String) async throws(RepositoryError) -> ActionOutcome {
        try await perform(
            taskID: taskID,
            landed: { $0.isDone },
            patch: { $0.with(status: .done, day: $0.day, allowedActions: []) }
        ) { () async throws(APIError) in
            _ = try await api.complete(taskID: taskID)
        }
    }

    public func reschedule(taskID: String, to day: CalendarDay) async throws(RepositoryError) -> ActionOutcome {
        try await perform(
            taskID: taskID,
            landed: { $0.day == day },
            patch: { $0.with(status: $0.status, day: day, allowedActions: $0.allowedActions) }
        ) { () async throws(APIError) in
            _ = try await api.reschedule(taskID: taskID, to: day)
        }
    }

    /// `landed` says whether a freshly fetched task already reflects the action; `patch` applies it
    /// locally if the follow-up refetch fails.
    private func perform(
        taskID: String,
        landed: (WorkTask) -> Bool,
        patch: (WorkTask) -> WorkTask,
        action: () async throws(APIError) -> Void
    ) async throws(RepositoryError) -> ActionOutcome {
        do {
            try await action()
        } catch .notConnected {
            throw .offline
        } catch .rateLimited {
            throw .busy
        } catch .notFound {
            try? await write { try await store.delete(ids: [taskID]) }
            throw .taskNotFound
        } catch .actionNotAllowed(let message) {
            // Either someone else got there first, or this is our own earlier attempt whose response was lost.
            try? await refreshWorkOrder(containing: taskID)
            if let task = await cachedTask(id: taskID), landed(task) { return .alreadyApplied }
            throw .rejected(message: message)
        } catch .connectionInterrupted {
            do {
                try await refreshWorkOrder(containing: taskID)
            } catch .taskNotFound {
                throw .taskNotFound
            } catch {
                throw .outcomeUnknown
            }
            if let task = await cachedTask(id: taskID), landed(task) { return .applied }
            throw .notApplied
        } catch {
            throw Self.map(error)
        }

        // The action response doesn't include the task, and completing one step changes what the
        // next step allows, so refetch the whole work order.
        do {
            try await refreshWorkOrder(containing: taskID)
        } catch {
            // The action landed. Don't report a failure just because the follow-up read didn't.
            if let task = await cachedTask(id: taskID) {
                try? await write { try await store.upsert([patch(task)]) }
            }
        }
        return .applied
    }

    private func write(_ body: () async throws -> Void) async throws(RepositoryError) {
        do {
            try await body()
        } catch {
            throw .unexpected("Couldn't save tasks on this device: \(error.localizedDescription)")
        }
        feed.send()
    }

    static func map(_ error: APIError) -> RepositoryError {
        switch error {
        case .notConnected: .offline
        case .connectionInterrupted: .offline
        case .rateLimited: .busy
        case .notFound: .taskNotFound
        case .actionNotAllowed(let message): .rejected(message: message)
        case .badRequest(let message): .unexpected("The app sent a request the server didn't accept: \(message)")
        case .server(let status, _): .unexpected("The server had a problem (\(status)).")
        case .invalidResponse: .unexpected("The server sent something the app didn't understand.")
        }
    }
}
