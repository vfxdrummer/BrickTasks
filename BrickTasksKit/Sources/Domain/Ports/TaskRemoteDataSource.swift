import Foundation

/// What the data layer needs from the server. Speaks domain types only; the Networking module
/// implements it and keeps its generated wire types to itself.
public protocol TaskRemoteDataSource: Sendable {
    /// Every task matching `query`, across all pages, de-duplicated by id.
    func tasks(matching query: TaskQuery) async throws(RemoteDataSourceError) -> [WorkTask]
    func task(id: String) async throws(RemoteDataSourceError) -> WorkTask
    func complete(taskID: String) async throws(RemoteDataSourceError) -> ActionReceipt
    func reschedule(taskID: String, to day: CalendarDay) async throws(RemoteDataSourceError) -> ActionReceipt
}

public struct TaskQuery: Hashable, Sendable {
    public var day: CalendarDay?
    public var workOrderID: String?
    public var status: TaskStatus?

    public init(day: CalendarDay? = nil, workOrderID: String? = nil, status: TaskStatus? = nil) {
        self.day = day
        self.workOrderID = workOrderID
        self.status = status
    }
}

public struct ActionReceipt: Hashable, Sendable {
    public let id: String
    public let taskID: String
    public let kind: TaskActionKind
    public let day: CalendarDay?
    public let appliedAt: Date

    public init(id: String, taskID: String, kind: TaskActionKind, day: CalendarDay?, appliedAt: Date) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.day = day
        self.appliedAt = appliedAt
    }
}

public enum RemoteDataSourceError: Error, Hashable, Sendable {
    /// 400: our request was wrong. A bug on our side, never the operator's.
    case badRequest(message: String)
    /// 404: no such task, or the whole sandbox URL has expired.
    case notFound(message: String)
    /// 409: the task doesn't accept this action right now, including a repeat of one that already landed.
    case actionNotAllowed(message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    /// The request never left the device. Safe to say "nothing happened".
    case notConnected
    /// The connection dropped mid-request. For an action, the server may or may not have applied it.
    case connectionInterrupted
    /// The response didn't match the contract.
    case invalidResponse(String)
}
