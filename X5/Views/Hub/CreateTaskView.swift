import SwiftUI

struct CreateTaskView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    var onCreated: () -> Void = {}

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var budget: String = ""
    // Несколько значений (Адильхан 30.10): пустые страны/города = «Все».
    @State private var categories: [String] = ["marketing"]
    // По умолчанию «Все страны» / «Все города» (Адильхан 30.10) — профиль не подставляем.
    @State private var countryCodes: [String] = []
    @State private var cities: [String] = []
    @State private var deadline: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var hasDeadline: Bool = false
    @State private var autoMessage: String = CreateTaskView.qaInitialAutoMessage
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    @StateObject private var hub = HubService()

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(loc.t("task_section"))) {
                    TextField("Заголовок", text: $title)
                    TextField("Описание", text: $description, axis: .vertical).lineLimit(3...8)
                }
                Section(
                    header: Text(loc.t("task_budget_category")),
                    footer: Text(loc.t("task_budget_optional_footer"))
                ) {
                    TextField(loc.t("task_budget_placeholder"), text: $budget)
                    TaskCategoriesPickerButton(categories: $categories)
                    Toggle("Срок", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Срок", selection: $deadline, displayedComponents: .date)
                    }
                }
                Section(header: Text(loc.t("task_location_section"))) {
                    TaskCountriesPickerButton(countryCodes: $countryCodes)
                    CISMultiCityPickerButton(cities: $cities, countryCodes: countryCodes)
                }
                TaskAutoMessageSection(text: $autoMessage)
                if let err = errorMessage {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Новое задание")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("btn_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if saving { ProgressView() } else { Text(loc.t("common_post")).bold() }
                    }
                    .disabled(saving || !canSubmit)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: countryCodes) { newCountries in
            cities = CISLocations.keptCities(cities, in: newCountries)
        }
    }

    #if DEBUG
    /// Только QA-скрин в симуляторе: готовый текст шаблона из окружения.
    private static var qaInitialAutoMessage: String {
        ProcessInfo.processInfo.environment["X5_CREATE_TASK_QA_AUTOMESSAGE"] ?? ""
    }
    #else
    private static var qaInitialAutoMessage: String { "" }
    #endif

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !categories.isEmpty
    }

    private var submittedBudget: String {
        let cleanBudget = budget.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanBudget.isEmpty ? loc.t("task_budget_discussed") : cleanBudget
    }

    private func submit() async {
        guard let uid = auth.userId, let token = auth.accessToken else { return }
        saving = true
        defer { saving = false }
        let inserted = await hub.createTask(
            authorId: uid,
            authorName: currentUser.profile?.name ?? auth.userEmail,
            authorAvatar: currentUser.profile?.avatar,
            companyName: nil,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            budget: submittedBudget,
            categories: categories,
            countryCodes: countryCodes,
            cities: cities,
            deadline: hasDeadline ? deadline : nil,
            autoMessage: autoMessage,
            accessToken: token
        )
        if inserted != nil {
            onCreated()
            dismiss()
        } else {
            errorMessage = "Could not post the task. Please try again."
        }
    }
}

/// Необязательный шаблон: сервер сам отправит его в чат один раз, когда
/// исполнитель откликнется. Общий для «Новое задание» и редактирования.
struct TaskAutoMessageSection: View {
    @Binding var text: String
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        Section(
            header: Text(loc.t("task_auto_message_section")),
            footer: Text(loc.t("task_auto_message_footer"))
        ) {
            TextField(loc.t("task_auto_message_placeholder"), text: $text, axis: .vertical)
                .lineLimit(3...8)
                .onChange(of: text) { newValue in
                    // Лимит базы — 1000 символов: лишнее обрезаем сразу при вводе.
                    let clamped = HubService.clampAutoMessage(newValue)
                    if clamped != newValue { text = clamped }
                }
        }
    }
}
