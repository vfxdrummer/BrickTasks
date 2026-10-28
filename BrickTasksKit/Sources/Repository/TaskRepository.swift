public import Domain
public import Foundation

/// What ViewModels use to read and change tasks. Reads come from the local copy and never fail;
/// refreshes and actions go to the server and report failures as `RepositoryError`.
public protocol TaskRepository: Sendable {
    func cachedDay(_ day: CalendarDay) async -> DaySnapshot
    func refreshDay(_ day: CalendarDay) async throws(RepositoryError) -> DaySnapshot

    func cachedTask(id: String) async -> WorkTask?
    func cachedWorkOrder(id: String) async -> [WorkTask]
    /// Refetches the task's whole work order. Throws `.taskNotFound` if the task no longer exists.
    func refreshWorkOrder(containing taskID: String) async throws(RepositoryError)

    func complete(taskID: String) async throws(RepositoryError) -> ActionOutcome
    func reschedule(taskID: String, to day: CalendarDay) async throws(RepositoryError) -> ActionOutcome

    /// Whether this build is pointed at a sandbox that can be reset.
    var canResetSandbox: Bool { get }
    /// Regenerates the sandbox's data and clears the local copy, since every date changes.
    func resetSandbox() async throws(RepositoryError)

    /// Fires after the local copy changes, so every screen can reload from it.
    func changes() -> AsyncStream<Void>
}

public struct DaySnapshot: Hashable, Sendable {
    public let day: CalendarDay
    public let tasks: [WorkTask]
    public let lastSyncedAt: Date?

    public init(day: CalendarDay, tasks: [WorkTask], lastSyncedAt: Date?) {
        self.day = day
        self.tasks = tasks
        self.lastSyncedAt = lastSyncedAt
    }
}

public enum ActionOutcome: Hashable, Sendable {
    case applied
    /// The server already had this change, made by someone else or by an earlier attempt whose
    /// response we lost.
    case alreadyApplied
}

public enum RepositoryError: Error, Hashable, Sendable {
    /// The request never reached the server. Nothing changed.
    case offline
    /// Rate limited. Nothing changed.
    case busy
    /// The server refused the action. The local copy has been refreshed to show why.
    case rejected(message: String)
    case taskNotFound
    /// The task list itself is gone (the sandbox URL expired or is wrong).
    case listUnavailable
    /// The connection dropped and we couldn't find out whether the action landed.
    case outcomeUnknown
    /// The connection dropped and a refetch shows the action did not land. Safe to try again.
    case notApplied
    case unexpected(String)
}
