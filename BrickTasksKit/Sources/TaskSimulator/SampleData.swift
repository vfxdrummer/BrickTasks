public import Domain
public import Foundation

/// Deterministic work orders around a given day, shaped like the sandbox's data.
public enum SampleData {
    public static func workOrders(around today: CalendarDay) -> [WorkTask] {
        let customers = ["Halcyon Coffee", "Tidewell Apparel", "Brightwater Skincare", "Foxglove Pet Supply", "Marlow Home Goods"]
        let plans: [(dayOffset: Int, times: [String], done: Int)] = [
            (-1, ["08:00", "11:00", "15:00"], 1),
            (0, ["07:30", "10:00", "13:30"], 1),
            (0, ["09:15", "12:00", "16:45"], 0),
            (0, ["14:00", "15:30", "17:00"], 0),
            (1, ["08:30", "11:30", "14:00"], 0),
        ]
        var tasks: [WorkTask] = []
        for (index, plan) in plans.enumerated() {
            let workOrder = WorkOrder(id: "wo_sample_\(index)", reference: "WO-\(10400 + index)", customer: customers[index])
            for (step, kind) in [TaskKind.pick, .pack, .ship].enumerated() {
                tasks.append(WorkTask(
                    id: "task_sample_\(index)_\(step + 1)", workOrder: workOrder, kind: kind, sequence: step + 1,
                    status: step < plan.done ? .done : .pending, day: today.adding(days: plan.dayOffset),
                    time: WallClockTime(plan.times[step])!, allowedActions: [], createdAt: Date(timeIntervalSince1970: 1_790_000_000)
                ))
            }
        }
        return tasks
    }
}
