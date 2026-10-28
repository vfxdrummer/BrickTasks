import Features
import SwiftUI

/// Creates the detail model once per pushed screen, so parent re-renders don't reset its state.
struct TaskDetailHost<Model: TaskDetailViewModeling>: View {
    @State private var model: Model
    let makeStep: @MainActor (String) -> Model

    init(make: @MainActor () -> Model, makeStep: @escaping @MainActor (String) -> Model) {
        _model = State(initialValue: make())
        self.makeStep = makeStep
    }

    var body: some View { TaskDetailScreen(model: model, makeStep: makeStep) }
}

struct TaskDetailScreen<Model: TaskDetailViewModeling>: View {
    let model: Model
    /// Builds the screen for another step in the same work order.
    let makeStep: @MainActor (String) -> Model
    @State private var isConfirmingComplete = false
    @State private var isRescheduling = false

    var body: some View {
        content
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Confirmations take the title's place for a few seconds: inline they shifted rows
                // under the operator's finger, and as an overlay they covered content or buttons.
                ToolbarItem(placement: .principal) {
                    if let confirmation = model.confirmation {
                        Label(confirmation, systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.green, in: Capsule())
                            .transition(.opacity)
                            .accessibilityIdentifier("confirmation")
                    } else {
                        Text(model.title).font(.headline)
                    }
                }
            }
            .task { await model.start() }
            .modifier(TickModifier { model.tick() })
            .task(id: model.confirmation) {
                guard model.confirmation != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                model.dismissConfirmation()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxHeight: .infinity)
        case .notFound:
            ContentUnavailableView("Task removed", systemImage: "trash", description: Text("This task no longer exists. It may have been removed by the office."))
        case .unavailable:
            ScrollView {
                ContentUnavailableView {
                    Label("Can't load task", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(model.banner?.message ?? "")
                } actions: {
                    Button("Try again") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
                }
            }
            .refreshable { await model.refresh() }
        case .loaded:
            loaded
        }
    }

    private var loaded: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if let banner = model.banner { BannerView(banner: banner) }
                    HStack {
                        Tag(text: model.statusText, color: statusColor).accessibilityIdentifier("status")
                        Spacer()
                    }
                    Text(model.title).font(.largeTitle.bold())
                    LabeledContent("Due", value: model.due).font(.title3)
                    LabeledContent("Work order", value: model.workOrder)
                    LabeledContent("Customer", value: model.customer)
                }
                .padding(.vertical, 4)
            }

            Section("Work order steps") {
                ForEach(model.steps) { step in
                    if step.isCurrent {
                        StepRowView(step: step)
                    } else {
                        // Pushes the view directly rather than by id: a value link whose id is already
                        // further back in the stack renders as permanently selected.
                        NavigationLink {
                            TaskDetailHost(make: { makeStep(step.id) }, makeStep: makeStep)
                        } label: {
                            StepRowView(step: step)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        // An overlay, not inline: content that jumps when a message appears or auto-hides
        // moves rows out from under the operator's finger.
        .animation(.easeInOut(duration: 0.25), value: model.confirmation)
        .confirmationDialog("Mark \(model.title.lowercased()) for \(model.workOrder) as done?", isPresented: $isConfirmingComplete, titleVisibility: .visible) {
            Button("Mark done") { Task { await model.completeTask() } }
        } message: {
            Text("This can't be undone from the app.")
        }
        .sheet(isPresented: $isRescheduling) {
            RescheduleSheet(range: model.rescheduleRange, suggested: model.suggestedRescheduleDate) { date in
                isRescheduling = false
                Task { await model.rescheduleTask(to: date) }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.complete != .hidden || model.reschedule != .hidden {
            VStack(spacing: 8) {
                if model.complete != .hidden {
                    Button {
                        isConfirmingComplete = true
                    } label: {
                        Label(model.isWorking ? "Saving…" : "Complete", systemImage: "checkmark")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!model.complete.isEnabled)
                    .accessibilityIdentifier("completeButton")
                    reason(model.complete)
                }
                if model.reschedule != .hidden {
                    Button {
                        isRescheduling = true
                    } label: {
                        Label("Reschedule", systemImage: "calendar")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.reschedule.isEnabled)
                    .accessibilityIdentifier("rescheduleButton")
                    if model.complete == .hidden || model.reschedule != model.complete { reason(model.reschedule) }
                }
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private func reason(_ availability: ActionAvailability) -> some View {
        if case .disabled(let reason) = availability {
            Text(reason).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("disabledReason")
        }
    }

    private var statusColor: Color {
        if model.isDone { return .green }
        if model.isOverdue { return .red }
        return .blue
    }
}

struct StepRowView: View {
    let step: StepRow

    var body: some View {
        HStack {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.isDone ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(step.title).font(step.isCurrent ? .headline : .body)
                Text(step.when).font(.subheadline).foregroundStyle(step.isOverdue ? .red : .secondary)
            }
            Spacer()
            if step.isCurrent { Text("This task").font(.caption).foregroundStyle(.secondary) }
            if step.isOverdue { Tag(text: "Overdue", color: .red) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RescheduleSheet: View {
    let range: ClosedRange<Date>
    let onConfirm: (Date) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(range: ClosedRange<Date>, suggested: Date, onConfirm: @escaping (Date) -> Void) {
        self.range = range
        self.onConfirm = onConfirm
        _date = State(initialValue: min(max(suggested, range.lowerBound), range.upperBound))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("New day", selection: $date, in: range, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                Button {
                    onConfirm(date)
                } label: {
                    Text("Move to \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("confirmReschedule")
                Text("The due time stays the same.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
