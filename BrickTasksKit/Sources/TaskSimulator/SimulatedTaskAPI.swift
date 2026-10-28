public import Domain
public import Foundation

/// An in-memory `TaskAPI` that enforces the real server's rules (sequencing, 409s, reschedule
/// keeps time). Lets tests and UI-test launches script network failures, including an action
/// that is applied on the server but whose response never arrives.
public actor SimulatedTaskAPI: TaskAPI, SandboxReset {
    public enum Operation: Hashable, Sendable {
        case list(TaskQuery)
        case get(String)
        case complete(String)
        case reschedule(String, CalendarDay)
        case reset
    }

    public enum OperationKind: Hashable, Sendable { case list, get, complete, reschedule, reset }

    public enum Failure: Hashable, Sendable {
        /// The request fails without reaching the server.
        case before(APIError)
        /// The server applies the request, then the response is lost.
        case after(APIError)
    }

    public private(set) var calls: [Operation] = []
    private var tasks: [String: WorkTask]
    private let initialTasks: [String: WorkTask]
    private var failures: [OperationKind: [Failure]] = [:]
    private var offline = false
    private var nextActionID = 1

    public init(tasks: [WorkTask] = []) {
        var byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for workOrderID in Set(tasks.map(\.workOrder.id)) { Self.recomputeAllowedActions(workOrderID, in: &byID) }
        self.tasks = byID
        self.initialTasks = byID
    }

    // MARK: Scripting

    /// Queues a failure for the next call of `kind`. Several queued failures are used in order.
    public func fail(_ kind: OperationKind, with failure: Failure) {
        failures[kind, default: []].append(failure)
    }

    /// Every request fails with `.notConnected` until set back.
    public func setOffline(_ offline: Bool) { self.offline = offline }

    /// Server-side change, as if office staff made it.
    public func officeEdit(_ task: WorkTask) {
        tasks[task.id] = task
        recomputeAllowedActions(task.workOrder.id)
    }

    public func officeDelete(id: String) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        recomputeAllowedActions(task.workOrder.id)
    }

    public func serverTask(id: String) -> WorkTask? { tasks[id] }

    // MARK: TaskAPI

    public func tasks(matching query: TaskQuery) async throws(APIError) -> [WorkTask] {
        calls.append(.list(query))
        return try perform(.list) {
            tasks.values
                .filter { query.day == nil || $0.day == query.day }
                .filter { query.workOrderID == nil || $0.workOrder.id == query.workOrderID }
                .filter { query.status == nil || $0.status == query.status }
                .sorted { ($0.day, $0.time, $0.id) < ($1.day, $1.time, $1.id) }
        }
    }

    public func task(id: String) async throws(APIError) -> WorkTask {
        calls.append(.get(id))
        return try perform(.get) { () throws(APIError) in
            guard let task = tasks[id] else { throw .notFound(message: "No such task") }
            return task
        }
    }

    public func complete(taskID: String) async throws(APIError) -> ActionReceipt {
        calls.append(.complete(taskID))
        return try perform(.complete) { () throws(APIError) in
            let task = try existing(taskID)
            guard task.canComplete else { throw .actionNotAllowed(message: refusal(for: task)) }
            store(task, status: .done, day: task.day)
            return receipt(taskID, .complete, day: nil)
        }
    }

    public func reschedule(taskID: String, to day: CalendarDay) async throws(APIError) -> ActionReceipt {
        calls.append(.reschedule(taskID, day))
        return try perform(.reschedule) { () throws(APIError) in
            let task = try existing(taskID)
            guard task.canReschedule else { throw .actionNotAllowed(message: refusal(for: task)) }
            store(task, status: task.status, day: day)
            return receipt(taskID, .reschedule, day: day)
        }
    }

    /// Like the real `/reset`: ids kept, dates and statuses back to their starting values.
    public func resetSandbox() async throws(APIError) {
        calls.append(.reset)
        try perform(.reset) { tasks = initialTasks }
    }

    // MARK: Rules

    private func perform<T>(_ kind: OperationKind, _ body: () throws(APIError) -> T) throws(APIError) -> T {
        if offline { throw .notConnected }
        switch failures[kind]?.isEmpty == false ? failures[kind]!.removeFirst() : nil {
        case .before(let error):
            throw error
        case .after(let error):
            _ = try body()
            throw error
        case nil:
            return try body()
        }
    }

    private func existing(_ id: String) throws(APIError) -> WorkTask {
        guard let task = tasks[id] else { throw .notFound(message: "No such task") }
        return task
    }

    private func refusal(for task: WorkTask) -> String {
        if task.isDone { return "\(name(task.kind)) is already done" }
        let blocker = tasks.values
            .filter { $0.workOrder.id == task.workOrder.id && $0.sequence < task.sequence && !$0.isDone }
            .min { $0.sequence < $1.sequence }
        return "\(name(task.kind)) cannot be completed until \(blocker.map { name($0.kind) } ?? "previous steps") is done"
    }

    private func store(_ task: WorkTask, status: TaskStatus, day: CalendarDay) {
        tasks[task.id] = task.with(status: status, day: day, allowedActions: task.allowedActions)
        recomputeAllowedActions(task.workOrder.id)
    }

    /// A task can be completed once every earlier task is done; a done task accepts nothing.
    private func recomputeAllowedActions(_ workOrderID: String) {
        Self.recomputeAllowedActions(workOrderID, in: &tasks)
    }

    private static func recomputeAllowedActions(_ workOrderID: String, in tasks: inout [String: WorkTask]) {
        let chain = tasks.values.filter { $0.workOrder.id == workOrderID }.sorted { $0.sequence < $1.sequence }
        var earlierAllDone = true
        for task in chain {
            let allowed: Set<TaskActionKind> = task.isDone ? [] : earlierAllDone ? [.complete, .reschedule] : [.reschedule]
            tasks[task.id] = task.with(status: task.status, day: task.day, allowedActions: allowed)
            earlierAllDone = earlierAllDone && task.isDone
        }
    }

    private func receipt(_ taskID: String, _ kind: TaskActionKind, day: CalendarDay?) -> ActionReceipt {
        defer { nextActionID += 1 }
        return ActionReceipt(id: "act_\(nextActionID)", taskID: taskID, kind: kind, day: day, appliedAt: Date())
    }

    private func name(_ kind: TaskKind) -> String {
        switch kind {
        case .pick: "pick"
        case .pack: "pack"
        case .ship: "ship"
        case .unknown(let raw): raw
        }
    }
}
