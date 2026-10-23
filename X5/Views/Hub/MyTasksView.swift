import SwiftUI

enum HubTaskPublicationAction: Equatable {
    case deactivate
    case reactivate

    static func forStatus(_ status: String) -> HubTaskPublicationAction? {
        switch status.lowercased() {
        case "open": return .deactivate
        case "cancelled": return .reactivate
        default: return nil
        }
    }

    var targetIsActive: Bool {
        self == .reactivate
    }
}

enum HubTaskStatusPresentation {
    static func localizationKey(for status: String) -> String? {
        switch status.lowercased() {
        case "open": return "my_tasks_status_open"
        case "cancelled": return "my_tasks_status_cancelled"
        case "in_progress": return "my_tasks_status_in_progress"
        case "done", "completed": return "my_tasks_status_completed"
        default: return nil
        }
    }
}

struct MyTasksView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService

    @StateObject private var hub = HubService()
    @State private var editingTask: HubTask?
    @State private var taskToDelete: HubTask?
    @State private var taskBeingChangedID: String?
    @State private var alertMessage: String?

    var body: some View {
        ScrollView {
            Group {
                if hub.isLoading && hub.myTasks.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if hub.myTasks.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(hub.myTasks) { task in
                            taskCard(task)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background { X5Background() }
        .navigationTitle(loc.t("my_tasks_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadTasks() }
        .refreshable { await loadTasks() }
        .sheet(item: $editingTask) { task in
            EditTaskView(hub: hub, task: task)
        }
        .confirmationDialog(
            loc.t("my_tasks_delete_title"),
            isPresented: Binding(
                get: { taskToDelete != nil },
                set: { if !$0 { taskToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(loc.t("btn_delete"), role: .destructive) {
                guard let task = taskToDelete else { return }
                taskToDelete = nil
                Task { await delete(task) }
            }
            Button(loc.t("btn_cancel"), role: .cancel) {
                taskToDelete = nil
            }
        } message: {
            Text(loc.t("my_tasks_delete_message"))
        }
        .alert(
            loc.t("common_load_failed"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(loc.t("my_tasks_empty"))
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
            Text(loc.t("my_tasks_empty_sub"))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }

    private func taskCard(_ task: HubTask) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let category = task.category, !category.isEmpty {
                        Label(
                            HubCategories.label(for: category, language: loc.current),
                            systemImage: HubCategories.symbol(for: category)
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    }
                }
                statusChip(task.status)
            }

            if let description = task.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(3)
            }

            HStack(spacing: 14) {
                if let budget = task.budget, !budget.isEmpty {
                    Label(budget, systemImage: "banknote")
                }
                if let deadline = formattedDeadline(task.deadline) {
                    Label(deadline, systemImage: "calendar")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.52))

            Divider().overlay(Color.white.opacity(0.1))

            HStack(spacing: 8) {
                ownerButton(
                    title: loc.t("my_tasks_edit"),
                    systemImage: "pencil",
                    tint: .white
                ) {
                    editingTask = task
                }

                if let action = HubTaskPublicationAction.forStatus(task.status) {
                    ownerButton(
                        title: action == .deactivate
                            ? loc.t("my_tasks_deactivate")
                            : loc.t("my_tasks_reactivate"),
                        systemImage: action == .deactivate ? "pause.fill" : "play.fill",
                        tint: action == .deactivate ? .orange : .accentColor
                    ) {
                        Task { await setPublication(task, action: action) }
                    }
                }

                Button(role: .destructive) {
                    taskToDelete = task
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 36, height: 34)
                        .background(Color.red.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(taskBeingChangedID == task.id)
            }

            if taskBeingChangedID == task.id {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(15)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.12)
    }

    private func ownerButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func statusChip(_ status: String) -> some View {
        Text(statusTitle(status))
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(statusColor(status))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(statusColor(status).opacity(0.13))
            .clipShape(Capsule())
    }

    private func statusTitle(_ status: String) -> String {
        if let key = HubTaskStatusPresentation.localizationKey(for: status) {
            return loc.t(key)
        }
        return status
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "open": return .accentColor
        case "cancelled": return .orange
        case "done", "completed": return .green
        default: return .blue
        }
    }

    private func formattedDeadline(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        guard let date = isoFormatter.date(from: raw) else {
            return String(raw.prefix(10))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: loc.current == .ru ? "ru_RU" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func loadTasks() async {
        guard let authorID = auth.userId,
              let token = await auth.freshAccessToken()
        else {
            alertMessage = loc.t("my_tasks_session_expired")
            return
        }
        _ = await hub.loadMyTasks(authorId: authorID, accessToken: token)
        if let error = hub.error {
            alertMessage = error
        }
    }

    private func setPublication(
        _ task: HubTask,
        action: HubTaskPublicationAction
    ) async {
        guard let authorID = auth.userId,
              authorID == task.authorId,
              let token = await auth.freshAccessToken()
        else {
            alertMessage = loc.t("my_tasks_session_expired")
            return
        }
        taskBeingChangedID = task.id
        defer { taskBeingChangedID = nil }
        let updated = await hub.setTaskActive(
            taskId: task.id,
            authorId: authorID,
            isActive: action.targetIsActive,
            accessToken: token
        )
        if updated == nil {
            X5Feedback.error()
            alertMessage = hub.error ?? loc.t("my_tasks_update_failed")
        } else {
            X5Feedback.success()
        }
    }

    private func delete(_ task: HubTask) async {
        guard let authorID = auth.userId,
              authorID == task.authorId,
              let token = await auth.freshAccessToken()
        else {
            alertMessage = loc.t("my_tasks_session_expired")
            return
        }
        taskBeingChangedID = task.id
        defer { taskBeingChangedID = nil }
        if await hub.deleteTask(
            taskId: task.id,
            authorId: authorID,
            accessToken: token
        ) {
            X5Feedback.success()
        } else {
            X5Feedback.error()
            alertMessage = hub.error ?? loc.t("my_tasks_delete_failed")
        }
    }
}

private struct EditTaskView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var hub: HubService
    private let task: HubTask

    @State private var title: String
    @State private var description: String
    @State private var budget: String
    @State private var category: String
    @State private var countryCode: String
    @State private var city: String
    @State private var deadline: Date
    @State private var hasDeadline: Bool
    @State private var saving = false
    @State private var errorMessage: String?

    init(hub: HubService, task: HubTask) {
        _hub = ObservedObject(wrappedValue: hub)
        self.task = task
        let parsedDeadline = Self.parseDeadline(task.deadline)
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _budget = State(initialValue: task.budget ?? "")
        _category = State(initialValue: task.category ?? "other")
        _countryCode = State(initialValue: task.countryCode ?? "KZ")
        _city = State(initialValue: task.city ?? "")
        _deadline = State(initialValue: parsedDeadline ?? Date())
        _hasDeadline = State(initialValue: parsedDeadline != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(loc.t("task_section"))) {
                    TextField(loc.t("my_tasks_title_placeholder"), text: $title)
                    TextField(
                        loc.t("my_tasks_description_placeholder"),
                        text: $description,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }

                Section(
                    header: Text(loc.t("task_budget_category")),
                    footer: Text(loc.t("task_budget_optional_footer"))
                ) {
                    TextField(loc.t("task_budget_placeholder"), text: $budget)
                    Picker(loc.t("my_tasks_category"), selection: $category) {
                        ForEach(HubCategories.all) { item in
                            Label(
                                HubCategories.label(for: item.id, language: loc.current),
                                systemImage: HubCategories.symbol(for: item.id)
                            )
                            .tag(item.id)
                        }
                    }
                    Toggle(loc.t("my_tasks_deadline"), isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker(
                            loc.t("my_tasks_deadline"),
                            selection: $deadline,
                            displayedComponents: .date
                        )
                    }
                }

                Section(header: Text(loc.t("task_location_section"))) {
                    Picker(loc.t("onb_country"), selection: $countryCode) {
                        ForEach(CISLocations.countries, id: \.code) { country in
                            Text(country.name).tag(country.code)
                        }
                    }
                    CISCityPickerButton(city: $city, countryCode: countryCode)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle(loc.t("my_tasks_edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("btn_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text(loc.t("btn_save")).bold()
                        }
                    }
                    .disabled(saving || !canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: countryCode) { _ in city = "" }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !countryCode.isEmpty &&
        city.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private func save() async {
        guard let authorID = auth.userId,
              authorID == task.authorId,
              let token = await auth.freshAccessToken()
        else {
            errorMessage = loc.t("my_tasks_session_expired")
            return
        }

        saving = true
        defer { saving = false }
        let cleanBudget = budget.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = await hub.updateTask(
            taskId: task.id,
            authorId: authorID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            budget: cleanBudget.isEmpty ? loc.t("task_budget_discussed") : cleanBudget,
            category: category,
            countryCode: countryCode,
            city: city.trimmingCharacters(in: .whitespacesAndNewlines),
            deadline: hasDeadline ? deadline : nil,
            accessToken: token
        )
        if updated != nil {
            X5Feedback.success()
            dismiss()
        } else {
            X5Feedback.error()
            errorMessage = hub.error ?? loc.t("my_tasks_update_failed")
        }
    }

    private static func parseDeadline(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}
