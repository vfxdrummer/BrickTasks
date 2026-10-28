import Foundation

/// The local copy of tasks. The repository reads from it first and writes server data into it.
public protocol TaskStore: Sendable {
    func tasks(on day: CalendarDay) async throws -> [WorkTask]
    func tasks(inWorkOrder workOrderID: String) async throws -> [WorkTask]
    func task(id: String) async throws -> WorkTask?
    /// Insert or update by id. A task whose day changed moves to its new day.
    func upsert(_ tasks: [WorkTask]) async throws
    func delete(ids: Set<String>) async throws
    /// Makes `tasks` the full contents of `day`: upserts them, and removes cached tasks still dated
    /// `day` that the server no longer returns (they were rescheduled away or deleted).
    func replace(day: CalendarDay, with tasks: [WorkTask], syncedAt: Date) async throws
    func lastSynced(day: CalendarDay) async throws -> Date?
    /// Removes every task and sync record.
    func deleteAll() async throws
}
