import Domain
import Foundation
import SwiftData

/// SwiftData row for a `WorkTask`. Enums are stored as their wire strings so unknown values
/// survive a round trip, and the day is stored as `YYYY-MM-DD` so it sorts and filters as text.
@Model
final class TaskRecord {
    @Attribute(.unique) var id: String
    var workOrderID: String
    var workOrderReference: String
    var customer: String
    var kind: String
    var sequence: Int
    var status: String
    var day: String
    var time: String
    var allowedActions: [String]
    var createdAt: Date

    init(_ task: WorkTask) {
        id = task.id
        workOrderID = task.workOrder.id
        workOrderReference = task.workOrder.reference
        customer = task.workOrder.customer
        kind = Self.raw(task.kind)
        sequence = task.sequence
        status = Self.raw(task.status)
        day = task.day.description
        time = task.time.description
        allowedActions = task.allowedActions.map(Self.raw).sorted()
        createdAt = task.createdAt
    }

    func update(from task: WorkTask) {
        workOrderID = task.workOrder.id
        workOrderReference = task.workOrder.reference
        customer = task.workOrder.customer
        kind = Self.raw(task.kind)
        sequence = task.sequence
        status = Self.raw(task.status)
        day = task.day.description
        time = task.time.description
        allowedActions = task.allowedActions.map(Self.raw).sorted()
        createdAt = task.createdAt
    }

    /// Nil only if the row was corrupted outside this type; such rows are skipped, not crashed on.
    var domain: WorkTask? {
        guard let day = CalendarDay(day), let time = WallClockTime(time) else { return nil }
        return WorkTask(
            id: id,
            workOrder: WorkOrder(id: workOrderID, reference: workOrderReference, customer: customer),
            kind: Self.kind(kind), sequence: sequence, status: Self.status(status),
            day: day, time: time,
            allowedActions: Set(allowedActions.map(Self.action)), createdAt: createdAt
        )
    }

    static func raw(_ kind: TaskKind) -> String {
        switch kind {
        case .pick: "pick"
        case .pack: "pack"
        case .ship: "ship"
        case .unknown(let raw): raw
        }
    }

    static func raw(_ status: TaskStatus) -> String {
        switch status {
        case .pending: "pending"
        case .done: "done"
        case .unknown(let raw): raw
        }
    }

    static func raw(_ action: TaskActionKind) -> String {
        switch action {
        case .complete: "complete"
        case .reschedule: "reschedule"
        case .unknown(let raw): raw
        }
    }

    static func kind(_ raw: String) -> TaskKind {
        switch raw {
        case "pick": .pick
        case "pack": .pack
        case "ship": .ship
        default: .unknown(raw)
        }
    }

    static func status(_ raw: String) -> TaskStatus {
        switch raw {
        case "pending": .pending
        case "done": .done
        default: .unknown(raw)
        }
    }

    static func action(_ raw: String) -> TaskActionKind {
        switch raw {
        case "complete": .complete
        case "reschedule": .reschedule
        default: .unknown(raw)
        }
    }
}

@Model
final class DaySyncRecord {
    @Attribute(.unique) var day: String
    var syncedAt: Date

    init(day: String, syncedAt: Date) {
        self.day = day
        self.syncedAt = syncedAt
    }
}
