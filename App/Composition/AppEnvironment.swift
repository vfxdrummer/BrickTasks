import Domain
import Features
import Foundation
import Networking
import OpenAPITaskClient
import Persistence
import Repository
import TaskSimulator

/// Composition root: the only place that picks concrete types for the app's protocols.
@MainActor
final class AppEnvironment {
    let repository: any TaskRepository
    let connectivity: any Connectivity
    let clock: any WarehouseClock

    init(repository: any TaskRepository, connectivity: any Connectivity, clock: any WarehouseClock) {
        self.repository = repository
        self.connectivity = connectivity
        self.clock = clock
    }

    func makeTaskList() -> TaskListViewModel {
        TaskListViewModel(repository: repository, connectivity: connectivity, clock: clock) { [unowned self] id in
            self.makeTaskDetail(taskID: id)
        }
    }

    func makeTaskDetail(taskID: String) -> TaskDetailViewModel {
        TaskDetailViewModel(taskID: taskID, repository: repository, connectivity: connectivity, clock: clock)
    }

    static func make(arguments: [String]) -> AppEnvironment {
        if let options = UITestOptions(arguments: arguments) { return uiTest(options) }
        return live()
    }

    private static func live() -> AppEnvironment {
        let clock = SystemWarehouseClock()
        let endpoints = OpenAPITaskEndpoints(baseURL: AppConfig.baseURL)
        let api = RemoteTaskAPI(endpoints: endpoints)
        let store: any TaskStore
        do {
            store = try SwiftDataTaskStore.make(url: storeURL(named: "Tasks.sqlite"))
        } catch {
            // A broken on-disk store must not stop operators from working online.
            store = try! SwiftDataTaskStore.make(inMemory: true)
        }
        return AppEnvironment(
            repository: OfflineFirstTaskRepository(api: api, store: store, clock: clock, sandbox: endpoints),
            connectivity: NetworkPathConnectivity(),
            clock: clock
        )
    }

    /// Deterministic launches for UI tests: simulated server, pinned clock, scriptable connectivity.
    /// The store is on disk so a test can relaunch offline and read what the previous launch saved.
    private static func uiTest(_ options: UITestOptions) -> AppEnvironment {
        let url = storeURL(named: "UITest.sqlite")
        if options.resetStore {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let clock = FixedWarehouseClock(now: options.now, timeZone: .current)
        let api = SimulatedTaskAPI(tasks: SampleData.workOrders(around: clock.today))
        if options.offline { Task { await api.setOffline(true) } }
        return AppEnvironment(
            repository: OfflineFirstTaskRepository(api: api, store: try! SwiftDataTaskStore.make(url: url), clock: clock, sandbox: api),
            connectivity: FixedConnectivity(isOnline: !options.offline),
            clock: clock
        )
    }

    private static func storeURL(named name: String) -> URL {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }
}

/// `-uiTesting [-resetStore] [-offline] [-time HH:MM]`
struct UITestOptions {
    let resetStore: Bool
    let offline: Bool
    let now: Date

    init?(arguments: [String]) {
        guard arguments.contains("-uiTesting") else { return nil }
        resetStore = arguments.contains("-resetStore")
        offline = arguments.contains("-offline")
        var now = Date()
        if let index = arguments.firstIndex(of: "-time"), index + 1 < arguments.count,
           let time = WallClockTime(arguments[index + 1]) {
            let today = CalendarDay(containing: Date(), in: .current)
            now = today.startDate(in: .current).addingTimeInterval(TimeInterval(time.hour * 3600 + time.minute * 60))
        }
        self.now = now
    }
}
