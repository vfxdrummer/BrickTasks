import Domain
import Features
import Foundation
import Persistence
import Repository
import TaskSimulator
import Testing

let utc = TimeZone.gmt
let today = CalendarDay("2026-10-28")!

func at(_ hhmm: String, on day: CalendarDay = today) -> Date {
    let time = WallClockTime(hhmm)!
    return day.startDate(in: utc).addingTimeInterval(TimeInterval(time.hour * 3600 + time.minute * 60))
}

final class TestClock: WarehouseClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    let timeZone = utc
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

final class TestConnectivity: Connectivity, @unchecked Sendable {
    private let lock = NSLock()
    private var online: Bool
    private var continuations: [AsyncStream<Bool>.Continuation] = []

    init(online: Bool = true) { self.online = online }

    var isOnline: Bool { lock.withLock { online } }

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        lock.withLock {
            continuations.append(continuation)
            continuation.yield(online)
        }
        return stream
    }

    func set(online: Bool) {
        let all = lock.withLock {
            self.online = online
            return continuations
        }
        for continuation in all { continuation.yield(online) }
    }
}

func chain(_ wo: String = "wo_1", day: CalendarDay = today, times: [String] = ["07:00", "08:00", "09:00"]) -> [WorkTask] {
    let workOrder = WorkOrder(id: wo, reference: "WO-\(wo)", customer: "Halcyon Coffee")
    return [TaskKind.pick, .pack, .ship].enumerated().map { index, kind in
        WorkTask(id: "\(wo)_\(index + 1)", workOrder: workOrder, kind: kind, sequence: index + 1, status: .pending,
                 day: day, time: WallClockTime(times[index])!, allowedActions: [], createdAt: .distantPast)
    }
}

/// ViewModels over the real repository and store, with the network faked by `SimulatedTaskServer`.
@MainActor
struct Harness {
    let server: SimulatedTaskServer
    let repository: OfflineFirstTaskRepository
    let clock: TestClock
    let connectivity: TestConnectivity

    init(tasks: [WorkTask] = chain(), now: Date = at("08:30"), online: Bool = true) throws {
        server = SimulatedTaskServer(tasks: tasks)
        clock = TestClock(now)
        connectivity = TestConnectivity(online: online)
        repository = OfflineFirstTaskRepository(remote: server, local: try SwiftDataTaskStore.make(inMemory: true), clock: clock, sandbox: server)
    }

    func detail(_ id: String) -> TaskDetailViewModel {
        TaskDetailViewModel(taskID: id, repository: repository, connectivity: connectivity, clock: clock, locale: Locale(identifier: "en_US"))
    }

    func list() -> TaskListViewModel {
        TaskListViewModel(repository: repository, connectivity: connectivity, clock: clock, locale: Locale(identifier: "en_US")) { id in
            self.detail(id)
        }
    }
}

/// Runs a screen's long-lived `start()` for the duration of `body`.
@MainActor
func running<VM: AnyObject>(_ vm: VM, start: @escaping @MainActor (VM) async -> Void, _ body: () async throws -> Void) async rethrows {
    let task = Task { await start(vm) }
    defer { task.cancel() }
    try await body()
}

/// Waits for async state to settle; fails the test if it never does.
@MainActor
func eventually(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition never became true", sourceLocation: sourceLocation)
}
