public import Domain
public import Foundation
public import SwiftData

/// `TaskLocalDataSource` on SwiftData. An actor with its own `ModelContext`, so callers on any thread are safe.
@ModelActor
public actor SwiftDataTaskStore: TaskLocalDataSource {
    /// `inMemory` is for tests and UI-test launches; the app uses the on-disk store.
    public static func make(inMemory: Bool = false) throws -> SwiftDataTaskStore {
        try make(ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory))
    }

    public static func make(url: URL) throws -> SwiftDataTaskStore {
        try make(ModelConfiguration(schema: schema, url: url))
    }

    private static let schema = Schema([TaskRecord.self, DaySyncRecord.self])

    /// Creating several containers for the same schema at once crashes inside Core Data
    /// (`createTriggersForEntities`, EXC_BAD_ACCESS). Seen when parallel tests each build a store.
    private static let containerCreation = NSLock()

    private static func make(_ configuration: ModelConfiguration) throws -> SwiftDataTaskStore {
        let container = try containerCreation.withLock { try ModelContainer(for: schema, configurations: configuration) }
        return SwiftDataTaskStore(modelContainer: container)
    }

    public func tasks(on day: CalendarDay) throws -> [WorkTask] {
        let key = day.description
        return try fetch(#Predicate<TaskRecord> { $0.day == key })
            .sorted { ($0.time, $0.workOrder.reference, $0.sequence) < ($1.time, $1.workOrder.reference, $1.sequence) }
    }

    public func tasks(inWorkOrder workOrderID: String) throws -> [WorkTask] {
        try fetch(#Predicate<TaskRecord> { $0.workOrderID == workOrderID }).sorted { $0.sequence < $1.sequence }
    }

    public func task(id: String) throws -> WorkTask? {
        try record(id: id)?.domain
    }

    public func upsert(_ tasks: [WorkTask]) throws {
        try upsertWithoutSaving(tasks)
        try modelContext.save()
    }

    public func delete(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        let ids = Array(ids)
        try modelContext.delete(model: TaskRecord.self, where: #Predicate { ids.contains($0.id) })
        try modelContext.save()
    }

    public func replace(day: CalendarDay, with tasks: [WorkTask], syncedAt: Date) throws {
        let key = day.description
        let keep = Set(tasks.map(\.id))
        for record in try modelContext.fetch(FetchDescriptor(predicate: #Predicate<TaskRecord> { $0.day == key }))
        where !keep.contains(record.id) {
            modelContext.delete(record)
        }
        try upsertWithoutSaving(tasks)
        let existing = try modelContext.fetch(FetchDescriptor(predicate: #Predicate<DaySyncRecord> { $0.day == key }))
        if let sync = existing.first {
            sync.syncedAt = syncedAt
        } else {
            modelContext.insert(DaySyncRecord(day: key, syncedAt: syncedAt))
        }
        // One save, so a reader never sees the day half-replaced.
        try modelContext.save()
    }

    public func lastSynced(day: CalendarDay) throws -> Date? {
        let key = day.description
        return try modelContext.fetch(FetchDescriptor(predicate: #Predicate<DaySyncRecord> { $0.day == key })).first?.syncedAt
    }

    public func deleteAll() throws {
        try modelContext.delete(model: TaskRecord.self)
        try modelContext.delete(model: DaySyncRecord.self)
        try modelContext.save()
    }

    private func upsertWithoutSaving(_ tasks: [WorkTask]) throws {
        for task in tasks {
            if let existing = try record(id: task.id) {
                existing.update(from: task)
            } else {
                modelContext.insert(TaskRecord(task))
            }
        }
    }

    private func record(id: String) throws -> TaskRecord? {
        var descriptor = FetchDescriptor(predicate: #Predicate<TaskRecord> { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetch(_ predicate: Predicate<TaskRecord>) throws -> [WorkTask] {
        try modelContext.fetch(FetchDescriptor(predicate: predicate)).compactMap(\.domain)
    }
}
