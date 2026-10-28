import Foundation

public struct WorkOrder: Hashable, Sendable {
    public let id: String
    public let reference: String
    public let customer: String

    public init(id: String, reference: String, customer: String) {
        self.id = id
        self.reference = reference
        self.customer = customer
    }
}

/// Open enums: a value the app doesn't know yet is kept rather than failing the whole response.
public enum TaskKind: Hashable, Sendable {
    case pick, pack, ship
    case unknown(String)
}

public enum TaskStatus: Hashable, Sendable {
    case pending, done
    case unknown(String)
}

public enum TaskActionKind: Hashable, Sendable {
    case complete, reschedule
    case unknown(String)
}

/// Named `WorkTask` to stay clear of Swift Concurrency's `Task`.
public struct WorkTask: Identifiable, Hashable, Sendable {
    public let id: String
    public let workOrder: WorkOrder
    public let kind: TaskKind
    public let sequence: Int
    public let status: TaskStatus
    public let day: CalendarDay
    public let time: WallClockTime
    public let allowedActions: Set<TaskActionKind>
    public let createdAt: Date

    public init(
        id: String, workOrder: WorkOrder, kind: TaskKind, sequence: Int, status: TaskStatus,
        day: CalendarDay, time: WallClockTime, allowedActions: Set<TaskActionKind>, createdAt: Date
    ) {
        self.id = id
        self.workOrder = workOrder
        self.kind = kind
        self.sequence = sequence
        self.status = status
        self.day = day
        self.time = time
        self.allowedActions = allowedActions
        self.createdAt = createdAt
    }

    public var isDone: Bool { status == .done }

    /// Buttons are gated on what the server says, not on client-side sequencing rules.
    public var canComplete: Bool { allowedActions.contains(.complete) }
    public var canReschedule: Bool { allowedActions.contains(.reschedule) }

    /// The due instant, reading `day` + `time` as wall-clock time in the warehouse's timezone.
    /// A time skipped by a DST jump resolves to the next valid instant.
    public func dueDate(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: day.year, month: day.month, day: day.day, hour: time.hour, minute: time.minute
        )
        return calendar.date(from: components)!
    }

    /// Not done and past its due time. An unknown status counts as not done, so the task stays
    /// visible to the operator rather than silently disappearing from the overdue view.
    public func isOverdue(at clock: WarehouseClock) -> Bool {
        !isDone && dueDate(in: clock.timeZone) < clock.now
    }
}
