public import Domain
public import Foundation
public import Observation
public import Repository

@MainActor
public protocol TaskListViewModeling: AnyObject, Observable {
    associatedtype Detail: TaskDetailViewModeling

    var title: String { get }
    var subtitle: String { get }
    var isShowingToday: Bool { get }
    var phase: TaskListPhase { get }
    var pending: [TaskRow] { get }
    var done: [TaskRow] { get }
    var overdueCount: Int { get }
    /// Customers with tasks on the selected day, for the filter picker.
    var customers: [String] { get }
    var selectedCustomer: String? { get }
    /// The selected customer's tasks grouped by work order; empty when no customer is selected.
    var workOrders: [WorkOrderGroup] { get }
    /// A customer is selected but has nothing on this day, though the day has other tasks.
    var isFilteredEmpty: Bool { get }
    var banner: Banner? { get }
    var isRefreshing: Bool { get }
    var selectedDate: Date { get }
    var canResetSandbox: Bool { get }

    /// Loads the cache, refreshes, then keeps listening for changes until cancelled.
    func start() async
    func refresh() async
    func showPreviousDay()
    func showNextDay()
    func showToday()
    func select(customer: String?)
    func show(date: Date)
    /// Re-evaluates time-based state (overdue). Called periodically by the view.
    func tick()
    func resetSandbox() async
    func makeDetail(taskID: String) -> Detail
}

public enum TaskListPhase: Hashable, Sendable {
    /// Nothing cached for this day and the first refresh hasn't finished.
    case loading
    case loaded
    /// The day has no tasks.
    case empty
    /// Nothing cached and the refresh failed. The banner says why; pull to refresh retries.
    case unavailable
}

public struct WorkOrderGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let reference: String
    public let progress: String
    public let rows: [TaskRow]
}

public struct TaskRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let workOrder: String
    public let customer: String
    public let time: String
    public let isDone: Bool
    public let isOverdue: Bool
    /// Pending but blocked by an earlier step in its work order.
    public let isWaiting: Bool
    public let accessibilityLabel: String
}

@MainActor
@Observable
public final class TaskListViewModel: TaskListViewModeling {
    public private(set) var day: CalendarDay
    public private(set) var phase: TaskListPhase = .loading
    public private(set) var banner: Banner?
    public private(set) var isRefreshing = false
    public private(set) var selectedCustomer: String?
    private var tasks: [WorkTask] = []
    private var lastSyncedAt: Date?
    private var isOnline = true
    private var lastError: RepositoryError?
    private var now: Date

    private let repository: any TaskRepository
    private let connectivity: any Connectivity
    private let clock: any WarehouseClock
    private let format: Formatters
    private let detailFactory: @MainActor (String) -> TaskDetailViewModel

    public init(
        repository: any TaskRepository,
        connectivity: any Connectivity,
        clock: any WarehouseClock,
        locale: Locale = .current,
        detailFactory: @escaping @MainActor (String) -> TaskDetailViewModel
    ) {
        self.repository = repository
        self.connectivity = connectivity
        self.clock = clock
        self.format = Formatters(clock: clock, locale: locale)
        self.detailFactory = detailFactory
        self.day = clock.today
        self.now = clock.now
    }

    // MARK: Derived state

    public var title: String { format.relativeDay(day) }
    public var subtitle: String { format.absoluteDay(day) }
    public var isShowingToday: Bool { day == clock.today }
    public var selectedDate: Date { day.startDate(in: clock.timeZone) }
    public var pending: [TaskRow] { visibleTasks.filter { !$0.isDone }.map(row) }
    public var done: [TaskRow] { visibleTasks.filter(\.isDone).map(row) }
    /// Counts what's on screen, so it follows the customer filter.
    public var overdueCount: Int { visibleTasks.filter(isOverdue).count }

    public var customers: [String] {
        Set(tasks.map(\.workOrder.customer)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var workOrders: [WorkOrderGroup] {
        guard selectedCustomer != nil else { return [] }
        let grouped = Dictionary(grouping: visibleTasks, by: \.workOrder.id)
        return grouped.values
            .map { $0.sorted { $0.sequence < $1.sequence } }
            // Earliest-due work order first, so the next thing to do is at the top.
            .sorted { ($0[0].time, $0[0].workOrder.reference) < ($1[0].time, $1[0].workOrder.reference) }
            .map { steps in
                let done = steps.filter(\.isDone).count
                return WorkOrderGroup(
                    id: steps[0].workOrder.id,
                    reference: steps[0].workOrder.reference,
                    progress: "\(done) of \(steps.count) done \(isShowingToday ? "today" : "on this day")",
                    rows: steps.map(row)
                )
            }
    }

    public var isFilteredEmpty: Bool {
        selectedCustomer != nil && visibleTasks.isEmpty && !tasks.isEmpty
    }

    private var visibleTasks: [WorkTask] {
        guard let selectedCustomer else { return tasks }
        return tasks.filter { $0.workOrder.customer == selectedCustomer }
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
        let requested = day
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await repository.refreshDay(requested)
            guard requested == day else { return }
            lastError = nil
            apply(snapshot)
        } catch {
            guard requested == day else { return }
            lastError = error
            if tasks.isEmpty && lastSyncedAt == nil { phase = .unavailable }
            updateBanner()
        }
    }

    public func showPreviousDay() { go(to: day.adding(days: -1)) }
    public func showNextDay() { go(to: day.adding(days: 1)) }
    public func showToday() { go(to: clock.today) }
    /// Kept across day changes: an operator working one customer's orders usually stays on them.
    public func select(customer: String?) { selectedCustomer = customer }
    public func show(date: Date) { go(to: CalendarDay(containing: date, in: clock.timeZone)) }
    public func tick() { now = clock.now }

    public var canResetSandbox: Bool { repository.canResetSandbox }

    public func resetSandbox() async {
        isRefreshing = true
        do {
            try await repository.resetSandbox()
            isRefreshing = false
            day = clock.today
            tasks = []
            lastSyncedAt = nil
            phase = .loading
            await refresh()
        } catch {
            isRefreshing = false
            lastError = error
            updateBanner()
        }
    }

    public func makeDetail(taskID: String) -> TaskDetailViewModel { detailFactory(taskID) }

    // MARK: Private

    private func go(to newDay: CalendarDay) {
        guard newDay != day else { return }
        day = newDay
        tasks = []
        lastSyncedAt = nil
        lastError = nil
        phase = .loading
        Task {
            await reloadFromCache()
            await refresh()
        }
    }

    private func reloadFromCache() async {
        let requested = day
        let snapshot = await repository.cachedDay(requested)
        guard requested == day else { return }
        if snapshot.lastSyncedAt != nil || !snapshot.tasks.isEmpty { apply(snapshot) }
    }

    private func apply(_ snapshot: DaySnapshot) {
        tasks = snapshot.tasks.sorted { ($0.time, $0.workOrder.reference, $0.sequence) < ($1.time, $1.workOrder.reference, $1.sequence) }
        lastSyncedAt = snapshot.lastSyncedAt
        phase = tasks.isEmpty ? .empty : .loaded
        now = clock.now
        updateBanner()
    }

    private func listenForChanges() async {
        for await _ in repository.changes() {
            await reloadFromCache()
        }
    }

    private func listenForConnectivity() async {
        for await online in connectivity.updates() {
            let cameBack = online && !isOnline
            isOnline = online
            updateBanner()
            // Wifi on the floor comes and goes; catch up as soon as it's back.
            if cameBack { await refresh() }
        }
    }

    private func updateBanner() {
        let saved = lastSyncedAt.map { "Showing tasks saved at \(format.clockTime($0))." } ?? "No saved tasks for this day."
        if !isOnline || lastError == .offline {
            banner = Banner(.offline, "Offline. \(saved)")
        } else if let lastError {
            banner = Banner(.error, "\(format.message(for: lastError)) \(lastSyncedAt == nil ? "" : saved)".trimmingCharacters(in: .whitespaces))
        } else {
            banner = nil
        }
    }

    private func isOverdue(_ task: WorkTask) -> Bool {
        task.isOverdue(at: FixedWarehouseClock(now: now, timeZone: clock.timeZone))
    }

    private func row(_ task: WorkTask) -> TaskRow {
        let overdue = isOverdue(task)
        let waiting = !task.isDone && !task.canComplete
        let title = format.kindName(task.kind)
        let time = format.time(task.time)
        var spoken = "\(title), \(task.workOrder.reference), \(task.workOrder.customer), due \(time)"
        if task.isDone { spoken += ", done" } else if overdue { spoken += ", overdue" }
        if waiting { spoken += ", waiting on an earlier step" }
        return TaskRow(
            id: task.id, title: title, workOrder: task.workOrder.reference, customer: task.workOrder.customer,
            time: time, isDone: task.isDone, isOverdue: overdue, isWaiting: waiting, accessibilityLabel: spoken
        )
    }
}
