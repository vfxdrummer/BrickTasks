import Domain
import Foundation
import Networking

/// Records every call and replies from a script, one reply per call, in order.
actor FakeTaskEndpoints: TaskEndpoints {
    enum Call: Hashable {
        case list(TaskQuery, offset: Int, limit: Int)
        case get(String)
        case action(TaskActionRequest)
    }

    private(set) var calls: [Call] = []
    private var listReplies: [Result<TaskPage, APIError>]
    private var getReplies: [Result<WorkTask, APIError>]
    private var actionReplies: [Result<ActionReceipt, APIError>]

    init(
        list: [Result<TaskPage, APIError>] = [],
        get: [Result<WorkTask, APIError>] = [],
        action: [Result<ActionReceipt, APIError>] = []
    ) {
        self.listReplies = list
        self.getReplies = get
        self.actionReplies = action
    }

    func listTasks(_ query: TaskQuery, offset: Int, limit: Int) async throws(APIError) -> TaskPage {
        calls.append(.list(query, offset: offset, limit: limit))
        return try listReplies.removeFirst().get()
    }

    func getTask(id: String) async throws(APIError) -> WorkTask {
        calls.append(.get(id))
        return try getReplies.removeFirst().get()
    }

    func createAction(_ action: TaskActionRequest) async throws(APIError) -> ActionReceipt {
        calls.append(.action(action))
        return try actionReplies.removeFirst().get()
    }
}

actor RecordingSleeper: Sleeper {
    private(set) var sleeps: [Double] = []
    func sleep(seconds: Double) async throws { sleeps.append(seconds) }
}

func makeTask(_ id: String, day: String = "2026-10-28") -> WorkTask {
    WorkTask(
        id: id,
        workOrder: WorkOrder(id: "wo_1", reference: "WO-1", customer: "Halcyon Coffee"),
        kind: .pick, sequence: 1, status: .pending,
        day: CalendarDay(day)!, time: WallClockTime("07:30")!,
        allowedActions: [.complete, .reschedule], createdAt: Date(timeIntervalSince1970: 0)
    )
}

func makeTasks(_ range: Range<Int>) -> [WorkTask] { range.map { makeTask("task_\($0)") } }

let receipt = ActionReceipt(id: "act_1", taskID: "task_1", kind: .complete, day: nil, appliedAt: Date(timeIntervalSince1970: 0))
