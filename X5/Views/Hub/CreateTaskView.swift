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
    @State private var countryCodes: [String] = ["KZ"]
    @State private var cities: [String] = []
    @State private var deadline: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var hasDeadline: Bool = false
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
        .onAppear {
            if let profileCountry = currentUser.profile?.countryCode, !profileCountry.isEmpty {
                countryCodes = [profileCountry]
            }
            let profileCity = (currentUser.profile?.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if cities.isEmpty, profileCity.count >= 2 { cities = [profileCity] }
        }
        .onChange(of: countryCodes) { newCountries in
            cities = CISLocations.keptCities(cities, in: newCountries)
        }
    }

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
