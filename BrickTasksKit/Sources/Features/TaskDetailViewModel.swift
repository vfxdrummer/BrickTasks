public import Domain
public import Foundation
public import Observation
public import Repository

@MainActor
public protocol TaskDetailViewModeling: AnyObject, Observable {
    var phase: TaskDetailPhase { get }
    var title: String { get }
    var workOrder: String { get }
    var customer: String { get }
    var due: String { get }
    var statusText: String { get }
    var isDone: Bool { get }
    var isOverdue: Bool { get }
    var steps: [StepRow] { get }
    var banner: Banner? { get }
    var confirmation: String? { get }
    var isWorking: Bool { get }
    var complete: ActionAvailability { get }
    var reschedule: ActionAvailability { get }
    /// The earliest day the picker offers. Moving work into the past only makes it overdue.
    var rescheduleRange: ClosedRange<Date> { get }
    var suggestedRescheduleDate: Date { get }

    func start() async
    func refresh() async
    func completeTask() async
    func rescheduleTask(to date: Date) async
    func dismissConfirmation()
    func tick()
}

public enum TaskDetailPhase: Hashable, Sendable {
    case loading
    case loaded
    /// The task isn't cached and couldn't be fetched (offline or error); the banner says which.
    case unavailable
    /// The server says the task no longer exists.
    case notFound
}

public struct StepRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let when: String
    public let isDone: Bool
    public let isOverdue: Bool
    public let isCurrent: Bool
}

@MainActor
@Observable
public final class TaskDetailViewModel: TaskDetailViewModeling {
    public let taskID: String
    public private(set) var phase: TaskDetailPhase = .loading
    public private(set) var banner: Banner?
    public private(set) var confirmation: String?
    public private(set) var isWorking = false
    private var task: WorkTask?
    private var chain: [WorkTask] = []
    private var isOnline = true
    private var now: Date

    private let repository: any TaskRepository
    private let connectivity: any Connectivity
    private let clock: any WarehouseClock
    private let format: Formatters

    public init(taskID: String, repository: any TaskRepository, connectivity: any Connectivity, clock: any WarehouseClock, locale: Locale = .current) {
        self.taskID = taskID
        self.repository = repository
        self.connectivity = connectivity
        self.clock = clock
        self.format = Formatters(clock: clock, locale: locale)
        self.now = clock.now
    }

    // MARK: Derived state

    public var title: String { task.map { format.kindName($0.kind) } ?? "Task" }
    public var workOrder: String { task?.workOrder.reference ?? "" }
    public var customer: String { task?.workOrder.customer ?? "" }
    public var due: String { task.map { "\(format.relativeDay($0.day)), \(format.time($0.time))" } ?? "" }
    public var isDone: Bool { task?.isDone ?? false }
    public var isOverdue: Bool { task.map(isOverdue) ?? false }

    public var statusText: String {
        guard let task else { return "" }
        if task.isDone { return "Done" }
        if isOverdue(task) { return "Overdue" }
        if !task.canComplete, let blocker = blocker(of: task) { return "Waiting on \(format.kindName(blocker.kind).lowercased())" }
        return "To do"
    }

    public var steps: [StepRow] {
        chain.map { step in
            StepRow(
                id: step.id, title: "\(step.sequence). \(format.kindName(step.kind))",
                when: "\(format.relativeDay(step.day)), \(format.time(step.time))",
                isDone: step.isDone, isOverdue: isOverdue(step), isCurrent: step.id == taskID
            )
        }
    }

    public var complete: ActionAvailability {
        guard let task, !task.isDone else { return .hidden }
        if !task.canComplete {
            let blocker = blocker(of: task).map { format.kindName($0.kind).lowercased() } ?? "an earlier step"
            return .disabled(reason: "Complete \(blocker) first.")
        }
        return availabilityWhenOnline()
    }

    public var reschedule: ActionAvailability {
        guard let task, !task.isDone else { return .hidden }
        guard task.canReschedule else { return .disabled(reason: "This task can't be rescheduled right now.") }
        return availabilityWhenOnline()
    }

    public var rescheduleRange: ClosedRange<Date> {
        let start = clock.today.startDate(in: clock.timeZone)
        return start...clock.today.adding(days: 365).startDate(in: clock.timeZone)
    }

    public var suggestedRescheduleDate: Date {
        let base = max(task?.day ?? clock.today, clock.today)
        return base.adding(days: 1).startDate(in: clock.timeZone)
    }

    // MARK: Intents

    public func start() async {
        // Read connectivity before the first refresh, so offline state never flashes as online.
        isOnline = await connectivity.isOnline
        await reloadFromCache()
        async let changes: Void = listenForChanges()
        async let network: Void = listenForConnectivity()
        await refresh()
        _ = await (changes, network)
    }

    public func refresh() async {
        do {
            try await repository.refreshWorkOrder(containing: taskID)
            await reloadFromCache()
            if !isOnline { return }
            banner = nil
        } catch .taskNotFound {
            await reloadFromCache()
            phase = .notFound
            banner = nil
        } catch {
            if task == nil { phase = .unavailable }
            banner = error == .offline
                ? Banner(.offline, task == nil ? "Offline. This task hasn't been saved on this device yet." : "Offline. Showing the saved copy.")
                : Banner(.error, format.message(for: error))
        }
    }

    public func completeTask() async {
        await run { [repository, taskID] () async throws(RepositoryError) -> String in
            switch try await repository.complete(taskID: taskID) {
            case .applied: "Marked done."
            case .alreadyApplied: "Already marked done."
            }
        }
    }

    public func rescheduleTask(to date: Date) async {
        let day = CalendarDay(containing: date, in: clock.timeZone)
        let label = format.relativeDay(day)
        await run { [repository, taskID] () async throws(RepositoryError) -> String in
            switch try await repository.reschedule(taskID: taskID, to: day) {
            case .applied: "Moved to \(label)."
            case .alreadyApplied: "Already scheduled for \(label)."
            }
        }
    }

    public func dismissConfirmation() { confirmation = nil }
    public func tick() { now = clock.now }

    // MARK: Private

    private func run(_ action: () async throws(RepositoryError) -> String) async {
        guard !isWorking else { return }
        isWorking = true
        confirmation = nil
        defer { isWorking = false }
        do {
            confirmation = try await action()
            banner = nil
        } catch .taskNotFound {
            phase = .notFound
        } catch {
            banner = Banner(error == .offline ? .offline : .error, format.message(for: error))
        }
        await reloadFromCache()
    }

    private func availabilityWhenOnline() -> ActionAvailability {
        if isWorking { return .disabled(reason: "Saving…") }
        return isOnline ? .enabled : .disabled(reason: "You're offline. Connect to make changes.")
    }

    private func reloadFromCache() async {
        guard let cached = await repository.cachedTask(id: taskID) else { return }
        task = cached
        chain = await repository.cachedWorkOrder(id: cached.workOrder.id)
        if phase != .notFound { phase = .loaded }
        now = clock.now
    }

    private func listenForChanges() async {
        for await _ in repository.changes() { await reloadFromCache() }
    }

    private func listenForConnectivity() async {
        for await online in connectivity.updates() {
            let cameBack = online && !isOnline
            isOnline = online
            if !online, task != nil { banner = Banner(.offline, "Offline. Showing the saved copy.") }
            if cameBack { await refresh() }
        }
    }

    private func blocker(of task: WorkTask) -> WorkTask? {
        chain.filter { $0.sequence < task.sequence && !$0.isDone }.min { $0.sequence < $1.sequence }
    }

    private func isOverdue(_ task: WorkTask) -> Bool {
        task.isOverdue(at: FixedWarehouseClock(now: now, timeZone: clock.timeZone))
    }
}
