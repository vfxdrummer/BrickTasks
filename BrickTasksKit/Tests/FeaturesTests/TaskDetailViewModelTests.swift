import Domain
import Features
import Foundation
import Testing

@MainActor
struct TaskDetailViewModelTests {
    @Test func showsTaskAndItsWholeWorkOrder() async throws {
        let h = try Harness(now: at("06:00"))
        let vm = h.detail("wo_1_2")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded && vm.steps.count == 3 }
            #expect(vm.title == "Pack")
            #expect(vm.workOrder == "WO-wo_1")
            #expect(vm.customer == "Halcyon Coffee")
            #expect(vm.due.hasPrefix("Today, 8:00"))
            #expect(vm.statusText == "Waiting on pick")
            #expect(vm.steps.map(\.title) == ["1. Pick", "2. Pack", "3. Ship"])
            #expect(vm.steps.map(\.isCurrent) == [false, true, false])
        }
    }

    @Test func blockedStepExplainsWhyCompleteIsDisabled() async throws {
        let h = try Harness()
        let vm = h.detail("wo_1_2")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded && vm.steps.count == 3 }
            #expect(vm.complete == .disabled(reason: "Complete pick first."))
            #expect(vm.reschedule == .enabled)
        }
    }

    @Test func completeMarksDoneAndUnlocksNextStep() async throws {
        let h = try Harness()
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.complete == .enabled)
            await vm.completeTask()
            #expect(vm.confirmation == "Marked done.")
            #expect(vm.isDone)
            #expect(vm.statusText == "Done")
            #expect(vm.complete == .hidden)
            #expect(vm.reschedule == .hidden)
            #expect(await h.repository.cachedTask(id: "wo_1_2")?.canComplete == true)
        }
    }

    @Test func overdueTaskSaysSo() async throws {
        let h = try Harness(now: at("07:01"))
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.isOverdue)
            #expect(vm.statusText == "Overdue")
        }
    }

    @Test func offlineDisablesActionsWithReason() async throws {
        let h = try Harness()
        _ = try await h.repository.refreshDay(today)
        await h.server.setOffline(true)
        h.connectivity.set(online: false)

        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded && vm.banner != nil }
            #expect(vm.banner == Banner(.offline, "Offline. Showing the saved copy."))
            #expect(vm.complete == .disabled(reason: "You're offline. Connect to make changes."))
            #expect(vm.reschedule == .disabled(reason: "You're offline. Connect to make changes."))
        }
    }

    @Test func actionThatFailsOfflineSaysNothingChanged() async throws {
        // Connectivity still claims online, but the request never leaves the device.
        let h = try Harness()
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            await h.server.setOffline(true)
            await vm.completeTask()
            #expect(vm.banner == Banner(.offline, "No connection. Nothing was changed."))
            #expect(!vm.isDone)
            #expect(vm.confirmation == nil)
        }
    }

    @Test func alreadyDoneByOfficeIsNotAnError() async throws {
        let h = try Harness()
        let vm = h.detail("wo_1_1")
        try await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            _ = try await h.server.complete(taskID: "wo_1_1")
            await vm.completeTask()
            #expect(vm.confirmation == "Already marked done.")
            #expect(vm.banner == nil)
            #expect(vm.isDone)
        }
    }

    @Test func unconfirmedOutcomeTellsOperatorToRefresh() async throws {
        let h = try Harness()
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            await h.server.fail(.complete, with: .after(.connectionInterrupted))
            await h.server.fail(.list, with: .before(.notConnected))
            await vm.completeTask()
            #expect(vm.banner?.message.contains("couldn't confirm") == true)
        }
    }

    @Test func rescheduleMovesTheTask() async throws {
        let h = try Harness()
        let vm = h.detail("wo_1_3")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            await vm.rescheduleTask(to: at("00:00", on: today.adding(days: 1)))
            #expect(vm.confirmation == "Moved to Tomorrow.")
            #expect(vm.due.hasPrefix("Tomorrow, 9:00"))
            #expect(await h.server.serverTask(id: "wo_1_3")?.day == today.adding(days: 1))
        }
    }

    @Test func reschedulePickerStartsTodayAndSuggestsTomorrow() throws {
        let h = try Harness()
        let vm = h.detail("wo_1_1")
        #expect(vm.rescheduleRange.lowerBound == at("00:00"))
        #expect(vm.suggestedRescheduleDate == at("00:00", on: today.adding(days: 1)))
    }

    @Test func suggestionForAFutureTaskIsTheDayAfterIt() async throws {
        let h = try Harness(tasks: chain(day: today.adding(days: 3)))
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            #expect(vm.suggestedRescheduleDate == at("00:00", on: today.adding(days: 4)))
        }
    }

    @Test func deletedTaskIsNotFound() async throws {
        let h = try Harness()
        await h.server.officeDelete(id: "wo_1_1")
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .notFound }
        }
    }

    @Test func uncachedTaskWhileOfflineIsUnavailable() async throws {
        let h = try Harness(online: false)
        await h.server.setOffline(true)
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .unavailable }
            #expect(vm.banner == Banner(.offline, "Offline. This task hasn't been saved on this device yet."))
        }
    }

    @Test func doubleTapCompletesOnce() async throws {
        let h = try Harness()
        let vm = h.detail("wo_1_1")
        await running(vm, start: { await $0.start() }) {
            await eventually { vm.phase == .loaded }
            async let first: Void = vm.completeTask()
            async let second: Void = vm.completeTask()
            _ = await (first, second)
            let completes = await h.server.calls.filter { if case .complete = $0 { true } else { false } }
            #expect(completes.count == 1)
        }
    }
}
