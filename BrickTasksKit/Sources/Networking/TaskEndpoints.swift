import Domain

/// One method = one HTTP request. This is the seam to whatever HTTP client we use: the app's
/// networking logic (paging, retries) sits above it, and the third-party client sits below it.
/// Implementations map their own wire types and failures to domain types and `APIError`.
public protocol TaskEndpoints: Sendable {
    func listTasks(_ query: TaskQuery, offset: Int, limit: Int) async throws(APIError) -> TaskPage
    func getTask(id: String) async throws(APIError) -> WorkTask
    func createAction(_ action: TaskActionRequest) async throws(APIError) -> ActionReceipt
}

public struct TaskPage: Hashable, Sendable {
    public let items: [WorkTask]
    public let total: Int
    public let offset: Int

    public init(items: [WorkTask], total: Int, offset: Int) {
        self.items = items
        self.total = total
        self.offset = offset
    }
}

public enum TaskActionRequest: Hashable, Sendable {
    case complete(taskID: String)
    case reschedule(taskID: String, day: CalendarDay)
}
