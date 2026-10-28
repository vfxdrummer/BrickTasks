import Domain

/// The app's `TaskAPI`: paging, de-duplication and read retries, on top of any `TaskEndpoints`.
public struct RemoteTaskAPI: TaskAPI {
    /// The server clamps anything above this.
    static let pageSize = 50
    /// Guards against a server that keeps reporting more items than it returns.
    static let maxPages = 40
    /// A longer `Retry-After` than this means waiting is worse than showing the cached copy.
    static let maxRetryAfter: Double = 5

    private let endpoints: any TaskEndpoints
    private let sleeper: any Sleeper

    public init(endpoints: any TaskEndpoints, sleeper: any Sleeper = TaskSleeper()) {
        self.endpoints = endpoints
        self.sleeper = sleeper
    }

    public func tasks(matching query: TaskQuery) async throws(APIError) -> [WorkTask] {
        var result: [WorkTask] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<Self.maxPages {
            let page = try await read { () async throws(APIError) in
                try await endpoints.listTasks(query, offset: offset, limit: Self.pageSize)
            }
            // Offsets shift while office staff edit, so the same task can show up on two pages.
            for task in page.items where seen.insert(task.id).inserted {
                result.append(task)
            }
            offset += page.items.count
            if page.items.isEmpty || offset >= page.total { return result }
        }
        throw .invalidResponse("Pagination did not finish after \(Self.maxPages) pages")
    }

    public func task(id: String) async throws(APIError) -> WorkTask {
        try await read { () async throws(APIError) in try await endpoints.getTask(id: id) }
    }

    /// Actions are never retried: the API has no idempotency key, so a retry isn't safe.
    /// Callers reconcile by refetching.
    public func complete(taskID: String) async throws(APIError) -> ActionReceipt {
        try await endpoints.createAction(.complete(taskID: taskID))
    }

    public func reschedule(taskID: String, to day: CalendarDay) async throws(APIError) -> ActionReceipt {
        try await endpoints.createAction(.reschedule(taskID: taskID, day: day))
    }

    /// Reads get one retry on 429, waiting the server's `Retry-After` (or 1s if it's missing).
    private func read<T>(_ operation: () async throws(APIError) -> T) async throws(APIError) -> T {
        do {
            return try await operation()
        } catch .rateLimited(let retryAfter) {
            let wait = retryAfter ?? 1
            guard wait <= Self.maxRetryAfter else { throw .rateLimited(retryAfter: retryAfter) }
            do { try await sleeper.sleep(seconds: wait) } catch { throw .rateLimited(retryAfter: retryAfter) }
            return try await operation()
        }
    }
}
