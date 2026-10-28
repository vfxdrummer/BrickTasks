import Domain
import Features
import Foundation
import Testing

@MainActor
struct TaskListViewModelTests {
    @Test func startsOnTodayAndLoadsFromServer() async throws {
        let h = try Harness()
        let vm = h.list()
        #expect(vm.title == "Today")
        #expect(vm.subtitle == "Wed, Oct 28")
        #expect(vm.phase == .loading)

        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.pending.map(\.title) == ["Pick", "Pack", "Ship"])
            #expect(vm.banner == nil)
        }
    }

    @Test func flagsOverdueAndWaitingRows() async throws {
        let h = try Harness(now: at("08:30"))
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.pending.map(\.isOverdue) == [true, true, false])
            #expect(vm.pending.map(\.isWaiting) == [false, true, true])
            #expect(vm.overdueCount == 2)
            #expect(vm.pending[0].accessibilityLabel.contains("overdue"))
        }
    }

    @Test func overdueUpdatesAsTimePasses() async throws {
        let h = try Harness(now: at("06:00"))
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.overdueCount == 0)
            h.clock.now = at("09:01")
            vm.tick()
            #expect(vm.overdueCount == 3)
        }
    }

    @Test func doneTasksAreSeparatedAndNeverOverdue() async throws {
        let h = try Harness(now: at("23:00"))
        _ = try await h.api.complete(taskID: "wo_1_1")
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.done.map(\.title) == ["Pick"])
            #expect(vm.done.first?.isOverdue == false)
            #expect(vm.overdueCount == 2)
        }
    }

    @Test func emptyDayIsEmptyNotLoading() async throws {
        let h = try Harness(tasks: [])
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .empty }
        }
    }

    @Test func offlineWithNothingSavedIsUnavailableWithReason() async throws {
        let h = try Harness(online: false)
        await h.api.setOffline(true)
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .unavailable }
            #expect(vm.banner == Banner(.offline, "Offline. No saved tasks for this day."))
        }
    }

    @Test func offlineAfterLoadKeepsShowingSavedTasks() async throws {
        let h = try Harness()
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            await h.api.setOffline(true)
            h.connectivity.set(online: false)
            await eventually { vm.banner?.style == .offline }
            await vm.refresh()
            #expect(vm.phase == .loaded)
            #expect(vm.pending.count == 3)
            #expect(vm.banner?.message.hasPrefix("Offline. Showing tasks saved at 8:30") == true)
        }
    }

    @Test func savedTasksShowOnRelaunchWhileOffline() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.api.setOffline(true)
        h.connectivity.set(online: false)

        let relaunched = h.list()
        await running(relaunched, start: { await $0.start() }) {
            await eventually { relaunched.phase == .loaded && relaunched.banner?.style == .offline }
            #expect(relaunched.pending.count == 3)
        }
    }

    @Test func comingBackOnlineRefreshesAutomatically() async throws {
        let h = try Harness(online: false)
        await h.api.setOffline(true)
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .unavailable }
            await h.api.setOffline(false)
            h.connectivity.set(online: true)
            await eventually { vm.phase == .loaded }
            #expect(vm.banner == nil)
        }
    }

    @Test func navigatesBetweenDays() async throws {
        let h = try Harness(tasks: chain() + chain("wo_2", day: today.adding(days: 1)))
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            vm.showNextDay()
            #expect(vm.title == "Tomorrow")
            #expect(!vm.isShowingToday)
            await eventually { vm.phase == .loaded && vm.pending.first?.workOrder == "WO-wo_2" }
            vm.showPreviousDay()
            vm.showPreviousDay()
            #expect(vm.title == "Yesterday")
            await eventually { vm.phase == .empty }
            vm.showToday()
            #expect(vm.isShowingToday)
            await eventually { vm.pending.first?.workOrder == "WO-wo_1" }
        }
    }

    @Test func pickingADateShowsThatDay() async throws {
        let h = try Harness()
        let vm = h.list()
        vm.show(date: at("15:00", on: today.adding(days: 5)))
        #expect(vm.subtitle == "Mon, Nov 2")
    }

    @Test func reflectsChangesMadeOnAnotherScreen() async throws {
        let h = try Harness(now: at("06:00"))
        let vm = h.list()
        try await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            _ = try await h.repository.complete(taskID: "wo_1_1")
            await eventually { vm.done.count == 1 }
            #expect(vm.pending.first?.isWaiting == false)
        }
    }

    @Test func expiredListSaysWhoToAsk() async throws {
        let h = try Harness()
        await h.api.fail(.list, with: .before(.notFound(message: "Not found")))
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .unavailable }
            #expect(vm.banner == Banner(.error, "The task list is unavailable. Contact your supervisor."))
        }
    }

    @Test func refreshErrorKeepsShowingSavedTasks() async throws {
        let h = try Harness()
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            await h.api.fail(.list, with: .before(.rateLimited(retryAfter: 1)))
            await vm.refresh()
            #expect(vm.phase == .loaded)
            #expect(vm.banner?.style == .error)
            #expect(vm.banner?.message.hasPrefix("The server is busy.") == true)
        }
    }

    @Test func resetReturnsToTodayWithFreshData() async throws {
        let h = try Harness()
        let vm = h.list()
        #expect(vm.canResetSandbox)
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            _ = try? await h.repository.complete(taskID: "wo_1_1")
            vm.showNextDay()
            await vm.resetSandbox()
            #expect(vm.isShowingToday)
            await eventually { vm.phase == .loaded && vm.done.isEmpty }
            #expect(vm.pending.count == 3)
        }
    }

    @Test func failedResetExplainsAndKeepsTasks() async throws {
        let h = try Harness()
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            await h.api.fail(.reset, with: .before(.notConnected))
            await vm.resetSandbox()
            #expect(vm.banner?.style == .offline)
            #expect(vm.pending.count == 3)
        }
    }
}

@MainActor
struct CustomerFilterTests {
    private func tasks() -> [WorkTask] {
        // wo_1 Halcyon Coffee at 07:00-09:00; wo_2 Tidewell Apparel at 06:00-10:00; wo_3 Halcyon Coffee at 11:00-13:00.
        let tidewell = chain("wo_2", times: ["06:00", "08:30", "10:00"]).map { task in
            WorkTask(id: task.id, workOrder: WorkOrder(id: "wo_2", reference: "WO-wo_2", customer: "Tidewell Apparel"),
                     kind: task.kind, sequence: task.sequence, status: task.status, day: task.day, time: task.time,
                     allowedActions: task.allowedActions, createdAt: task.createdAt)
        }
        return chain() + tidewell + chain("wo_3", times: ["11:00", "12:00", "13:00"])
    }

    @Test func listsCustomersForTheDayAlphabetically() async throws {
        let h = try Harness(tasks: tasks())
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.customers == ["Halcyon Coffee", "Tidewell Apparel"])
            #expect(vm.selectedCustomer == nil)
            #expect(vm.workOrders.isEmpty)
            #expect(vm.pending.count == 9)
        }
    }

    @Test func selectingACustomerGroupsTheirTasksByWorkOrder() async throws {
        let h = try Harness(tasks: tasks())
        _ = try await h.api.complete(taskID: "wo_1_1")
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            vm.select(customer: "Halcyon Coffee")

            #expect(vm.workOrders.map(\.reference) == ["WO-wo_1", "WO-wo_3"])
            #expect(vm.workOrders[0].rows.map(\.title) == ["Pick", "Pack", "Ship"])
            #expect(vm.workOrders[0].progress == "1 of 3 done today")
            #expect(vm.workOrders[1].progress == "0 of 3 done today")
            #expect(vm.pending.allSatisfy { $0.customer == "Halcyon Coffee" })
        }
    }

    @Test func overdueCountFollowsTheFilter() async throws {
        let h = try Harness(tasks: tasks(), now: at("08:45"))
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.overdueCount == 4) // Halcyon pick, pack; Tidewell pick, pack
            vm.select(customer: "Tidewell Apparel")
            #expect(vm.overdueCount == 2)
            vm.select(customer: nil)
            #expect(vm.overdueCount == 4)
        }
    }

    @Test func filterSurvivesDayChangeAndExplainsEmptyDays() async throws {
        let h = try Harness(tasks: tasks() + chain("wo_9", day: today.adding(days: 1)))
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            vm.select(customer: "Tidewell Apparel")
            vm.showNextDay()
            await eventually { vm.phase == .loaded }
            #expect(vm.selectedCustomer == "Tidewell Apparel")
            #expect(vm.isFilteredEmpty)
            #expect(vm.customers == ["Halcyon Coffee"])
            vm.select(customer: nil)
            #expect(!vm.isFilteredEmpty)
            #expect(vm.pending.count == 3)
        }
    }

    @Test func worksOfflineFromSavedTasks() async throws {
        let h = try Harness(tasks: tasks())
        _ = try await h.repository.refreshDay(today)
        await h.api.setOffline(true)
        h.connectivity.set(online: false)
        let vm = h.list()
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            vm.select(customer: "Halcyon Coffee")
            #expect(vm.workOrders.count == 2)
        }
    }
}
