import Features
import SwiftUI

struct TaskListScreen<Model: TaskListViewModeling>: View {
    let model: Model
    @State private var isPickingDate = false
    @State private var isConfirmingReset = false

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .navigationTitle("Tasks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Pick a date", systemImage: "calendar") { isPickingDate = true }
                            .accessibilityIdentifier("pickDate")
                    }
                    if model.canResetSandbox {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu("More", systemImage: "ellipsis.circle") {
                                Button("Reset sandbox data", systemImage: "arrow.counterclockwise", role: .destructive) {
                                    isConfirmingReset = true
                                }
                            }
                            .accessibilityIdentifier("moreMenu")
                        }
                    }
                }
                .navigationDestination(for: String.self) { taskID in
                    TaskDetailHost(make: { model.makeDetail(taskID: taskID) })
                }
                .sheet(isPresented: $isPickingDate) { datePicker }
                .confirmationDialog("Reset sandbox data?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { Task { await model.resetSandbox() } }
                } message: {
                    Text("Every task goes back to its starting state, re-dated around today. Saved copies on this device are cleared.")
                }
        }
        .task { await model.start() }
        .modifier(TickModifier { model.tick() })
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Previous day", systemImage: "chevron.left", action: model.showPreviousDay)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("previousDay")
                Spacer()
                VStack(spacing: 2) {
                    Text(model.title).font(.title2.bold()).accessibilityIdentifier("dayTitle")
                    Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button("Next day", systemImage: "chevron.right", action: model.showNextDay)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("nextDay")
            }
            .font(.title3)

            HStack {
                if model.overdueCount > 0 {
                    Label("\(model.overdueCount) overdue", systemImage: "clock.badge.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("overdueCount")
                }
                Spacer()
                if !model.isShowingToday {
                    Button("Back to today", action: model.showToday)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("todayButton")
                }
            }
            .frame(minHeight: 32)

            if let banner = model.banner { BannerView(banner: banner) }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading tasks…").frame(maxHeight: .infinity)
        case .empty:
            ScrollView {
                ContentUnavailableView("No tasks", systemImage: "checkmark.circle", description: Text("Nothing is scheduled for this day."))
                    .padding(.top, 60)
            }
            .refreshable { await model.refresh() }
        case .unavailable:
            ScrollView {
                ContentUnavailableView {
                    Label("Can't load tasks", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(model.banner?.message ?? "")
                } actions: {
                    Button("Try again") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            }
            .refreshable { await model.refresh() }
        case .loaded:
            List {
                if !model.pending.isEmpty {
                    Section("To do · \(model.pending.count)") {
                        ForEach(model.pending) { row in
                            NavigationLink(value: row.id) { TaskRowView(row: row) }
                        }
                    }
                }
                if !model.done.isEmpty {
                    Section("Done · \(model.done.count)") {
                        ForEach(model.done) { row in
                            NavigationLink(value: row.id) { TaskRowView(row: row) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refresh() }
        }
    }

    private var datePicker: some View {
        NavigationStack {
            DatePicker("Day", selection: Binding(get: { model.selectedDate }, set: { model.show(date: $0); isPickingDate = false }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Go to day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { isPickingDate = false } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TaskRowView: View {
    let row: TaskRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(row.time)
                .font(.headline.monospacedDigit())
                .foregroundStyle(row.isOverdue ? .red : .primary)
                .frame(minWidth: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title).font(.headline)
                    if row.isOverdue { Tag(text: "Overdue", color: .red) }
                    if row.isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text("\(row.workOrder) · \(row.customer)").font(.subheadline).foregroundStyle(.secondary)
                if row.isWaiting {
                    Label("Waiting on earlier step", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(row.isDone ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
