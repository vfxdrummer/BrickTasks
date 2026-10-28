internal import Domain
internal import Foundation

/// Generated wire types -> domain. Pure functions; a malformed task fails the whole response
/// rather than being dropped, because a silently missing task is worse on the floor than an error
/// shown over the cached list.
enum TaskMapper {
    typealias Wire = Components.Schemas

    static func task(_ wire: Wire.Task) throws(APIError) -> WorkTask {
        guard let day = CalendarDay(wire.date) else {
            throw .invalidResponse("Task \(wire.id) has invalid date \"\(wire.date)\"")
        }
        guard let time = WallClockTime(wire.time) else {
            throw .invalidResponse("Task \(wire.id) has invalid time \"\(wire.time)\"")
        }
        return WorkTask(
            id: wire.id,
            workOrder: WorkOrder(
                id: wire.workOrder.id,
                reference: wire.workOrder.reference,
                customer: wire.workOrder.customer
            ),
            kind: kind(wire.kind),
            sequence: wire.sequence,
            status: status(wire.status),
            day: day,
            time: time,
            allowedActions: Set(wire.allowedActions.map(actionKind)),
            createdAt: wire.createdAt
        )
    }

    static func receipt(_ wire: Wire.ActionRecord) throws(APIError) -> ActionReceipt {
        var day: CalendarDay?
        if let date = wire.date {
            guard let parsed = CalendarDay(date) else {
                throw .invalidResponse("Action \(wire.id) has invalid date \"\(date)\"")
            }
            day = parsed
        }
        return ActionReceipt(
            id: wire.id, taskID: wire.taskId, kind: actionKind(wire.kind), day: day, appliedAt: wire.appliedAt
        )
    }

    /// The server only accepts the statuses it knows; asking for an unknown one would be a 400.
    static func wireStatus(_ status: TaskStatus) throws(APIError) -> Wire.KnownTaskStatus {
        switch status {
        case .pending: .pending
        case .done: .done
        case .unknown(let raw): throw .badRequest(message: "Cannot filter by unknown status \"\(raw)\"")
        }
    }

    // In an open enum, a known value fills `value1` (and `value2`); an unknown one only `value2`.
    static func kind(_ wire: Wire.TaskKind) -> TaskKind {
        switch wire.value1 {
        case .pick: .pick
        case .pack: .pack
        case .ship: .ship
        case nil: .unknown(wire.value2 ?? "")
        }
    }

    static func status(_ wire: Wire.TaskStatus) -> TaskStatus {
        switch wire.value1 {
        case .pending: .pending
        case .done: .done
        case nil: .unknown(wire.value2 ?? "")
        }
    }

    static func actionKind(_ wire: Wire.ActionKind) -> TaskActionKind {
        switch wire.value1 {
        case .complete: .complete
        case .reschedule: .reschedule
        case nil: .unknown(wire.value2 ?? "")
        }
    }
}
