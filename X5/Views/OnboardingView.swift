import SwiftUI

/// Mandatory after first sign in: collect identity, role and work location.
/// New registrations expose exactly two roles: specialist and entrepreneur.
struct OnboardingView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    private let maxPickedCategories = 8

    @State private var role: Role?
    @State private var step: Step = .role
    @State private var name: String = ""
    @State private var nickname: String = ""
    @State private var countryCode: String = "KZ"
    @State private var city: String = ""
    @State private var pickedCategories: Set<String> = []
    @State private var saving = false
    @State private var errorMessage: String?

    enum Step {
        case role
        case location
        case name
        case nickname
    }

    enum Role: String, CaseIterable, Identifiable {
        case specialist
        case entrepreneur

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                switch step {
                case .role:
                    roleSection
                    if role == .specialist {
                        categoriesSection
                    }
                case .location:
                    locationSection
                case .name:
                    nameSection
                case .nickname:
                    nicknameSection
                }

                submitSection
            }
            .scrollContentBackground(.hidden)
            .background { X5Background() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if step != .role {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: goBack) {
                            Label(loc.t("btn_back"), systemImage: "chevron.left")
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("onboarding_back_button")
                    }
                }
            }
        }
        .tint(.accentColor)
        .preferredColorScheme(.dark)
        .onAppear { populateProfileFields() }
        .onChange(of: currentUser.profile) { _ in populateProfileFields() }
        .onChange(of: role) { newRole in
            if newRole != .specialist {
                pickedCategories.removeAll()
            }
        }
        .onChange(of: countryCode) { newCountry in
            if newCountry != currentUser.profile?.countryCode { city = "" }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text(stepTitle)
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(stepSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
    }

    private var nameSection: some View {
        Section {
            TextField(loc.t("edit_name_placeholder"), text: $name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .onSubmit { advanceOrSubmit() }
        } header: {
            Text(loc.t("onb_identity_section"))
        } footer: {
            Text(nameFooter)
        }
    }

    private var nicknameSection: some View {
        Section {
            TextField(loc.t("edit_nickname_placeholder"), text: $nickname)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocapitalization(.none)
                .submitLabel(role == .specialist ? .next : .done)
                .onSubmit { advanceOrSubmit() }
                .onChange(of: nickname) { value in
                    let cleaned = Self.cleanNickname(value)
                    if cleaned != value {
                        nickname = cleaned
                    }
                }
        } header: {
            Text(loc.t("onb_identity_section"))
        } footer: {
            Text(nicknameFooter)
        }
    }

    private var locationSection: some View {
        Section {
            Picker(loc.t("onb_country"), selection: $countryCode) {
                ForEach(CISLocations.countries, id: \.code) { country in
                    Text(country.name).tag(country.code)
                }
            }

            CISCityPickerButton(city: $city, countryCode: countryCode)
        } header: {
            Text(loc.t("onb_location_section"))
        } footer: {
            Text(loc.t("onb_location_hint"))
        }
    }

    private var roleSection: some View {
        Section {
            Picker(loc.t("onb_role_section"), selection: $role) {
                Text(loc.t("onb_role_specialist")).tag(Role?.some(.specialist))
                Text(loc.t("onb_role_entrepreneur")).tag(Role?.some(.entrepreneur))
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(roleFooter)
        }
    }

    private var categoriesSection: some View {
        Section {
            ForEach(HubCategories.all) { cat in
                let selected = pickedCategories.contains(cat.id)
                Toggle(isOn: categoryBinding(for: cat.id)) {
                    Label(HubCategories.label(for: cat.id, language: loc.current), systemImage: HubCategories.symbol(for: cat.id))
                }
                .disabled(!selected && pickedCategories.count >= maxPickedCategories)
            }
        } header: {
            Text(loc.t("onb_pick_categories"))
        } footer: {
            Text("\(pickedCategories.count)/\(maxPickedCategories)")
        }
    }

    private var submitSection: some View {
        Section {
            Button(action: advanceOrSubmit) {
                HStack {
                    if saving {
                        ProgressView()
                            .tint(onboardingPrimaryButtonForeground)
                    }
                    Text(saving ? loc.t("onb_saving") : primaryButtonTitle)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(onboardingPrimaryButtonForeground)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(onboardingPrimaryButtonTint)
            .disabled(!onboardingPrimaryButtonIsEnabled)
        } footer: {
            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .role:
            return loc.t("onb_title")
        case .location:
            return loc.t("onb_location_step_title")
        case .name:
            return loc.t("onb_name_step_title")
        case .nickname:
            return loc.t("onb_nickname_step_title")
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .role:
            return loc.t("onb_subtitle")
        case .location:
            return loc.t("onb_location_step_subtitle")
        case .name:
            return loc.t("onb_name_step_subtitle")
        case .nickname:
            return loc.t("onb_nickname_step_subtitle")
        }
    }

    private var primaryButtonTitle: String {
        if isFinalStep {
            return loc.t("onb_finish")
        }
        return loc.t("onb_continue")
    }

    private var onboardingPrimaryButtonIsEnabled: Bool {
        canAdvance && !saving
    }

    private var onboardingPrimaryButtonForeground: Color {
        if onboardingPrimaryButtonIsEnabled {
            return .black
        }
        return .white.opacity(0.72)
    }

    private var onboardingPrimaryButtonTint: Color {
        if onboardingPrimaryButtonIsEnabled {
            return .accentColor
        }
        return .white.opacity(0.22)
    }

    private var nameFooter: String {
        if !nameTrimmed.isEmpty && !hasRealName {
            return loc.t("onb_name_required")
        }
        return loc.t("onb_name_hint")
    }

    private var nicknameFooter: String {
        if !nicknameTrimmed.isEmpty && !isValidNickname {
            return loc.t("onb_nickname_required")
        }
        return loc.t("onb_nickname_hint")
    }

    private var roleFooter: String {
        switch role {
        case .specialist:
            return loc.t("onb_role_specialist_sub")
        case .entrepreneur:
            return loc.t("onb_role_entrepreneur_sub")
        case nil:
            return loc.t("onb_role_required")
        }
    }

    private var canSubmit: Bool {
        guard let role else { return false }
        guard hasRealName, isValidNickname, !countryCode.isEmpty, cityTrimmed.count >= 2 else { return false }
        if role == .specialist { return !pickedCategories.isEmpty }
        return true
    }

    private var canAdvance: Bool {
        switch step {
        case .role:
            guard let role else { return false }
            return role != .specialist || !pickedCategories.isEmpty
        case .location:
            return !countryCode.isEmpty && cityTrimmed.count >= 2
        case .name:
            return hasRealName
        case .nickname:
            return isValidNickname
        }
    }

    private var isFinalStep: Bool {
        switch step {
        case .role, .location, .name:
            return false
        case .nickname:
            return true
        }
    }

    private var nameTrimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nicknameTrimmed: String {
        Self.cleanNickname(nickname.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var cityTrimmed: String {
        city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasRealName: Bool {
        let value = nameTrimmed
        let lower = value.lowercased()
        return value.count >= 2 && lower != "user" && lower != "x5"
    }

    private var isValidNickname: Bool {
        nicknameTrimmed.range(of: "^[a-z0-9_]{3,}$", options: .regularExpression) != nil
    }

    private static func cleanNickname(_ value: String) -> String {
        value.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }
    }

    private func categoryBinding(for id: String) -> Binding<Bool> {
        Binding {
            pickedCategories.contains(id)
        } set: { isSelected in
            if isSelected {
                if pickedCategories.count < maxPickedCategories {
                    pickedCategories.insert(id)
                }
            } else {
                pickedCategories.remove(id)
            }
        }
    }

    private func populateProfileFields() {
        guard let p = currentUser.profile else { return }
        let profileName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !profileName.isEmpty && profileName.lowercased() != "user" && profileName.lowercased() != "x5" {
            name = profileName
        }
        nickname = Self.cleanNickname((p.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        countryCode = p.countryCode ?? countryCode
        city = p.city ?? city
        if p.userRole == "creator" {
            role = .entrepreneur
        } else if let storedRole = Role(rawValue: p.userRole ?? "") {
            role = storedRole
        }
        pickedCategories = Set(p.specialistCategory ?? [])
    }

    private func advanceOrSubmit() {
        guard canAdvance else { return }
        switch step {
        case .role:
            step = .location
        case .location:
            step = .name
        case .name:
            step = .nickname
        case .nickname:
            submit()
        }
    }

    private func goBack() {
        guard !saving else { return }
        errorMessage = nil
        switch step {
        case .role:
            break
        case .location:
            step = .role
        case .name:
            step = .location
        case .nickname:
            step = .name
        }
    }

    private func submit() {
        guard let role else { return }
        saving = true
        errorMessage = nil
        Task {
            do {
                guard let token = await auth.freshAccessToken() else {
                    throw NSError(domain: "Onboarding", code: 401, userInfo: [NSLocalizedDescriptionKey: loc.t("onb_session_expired")])
                }
                try await patchProfile(role: role, token: token)
                if let uid = auth.userId {
                    await currentUser.load(userId: uid, accessToken: token)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }

    private func patchProfile(role: Role, token: String) async throws {
        guard let userId = auth.userId else { return }
        let baseURL = X5Config.supabaseBaseURL
        let anonKey = X5Config.supabaseAnonKey
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "Onboarding", code: -1, userInfo: [NSLocalizedDescriptionKey: loc.t("onb_save_failed")])
        }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(userId)")]
        guard let url = components.url else {
            throw NSError(domain: "Onboarding", code: -1, userInfo: [NSLocalizedDescriptionKey: loc.t("onb_save_failed")])
        }

        let categories = role == .specialist ? Array(pickedCategories) : []
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let body: [String: Any] = [
            "name": nameTrimmed,
            "nickname": nicknameTrimmed,
            "user_role": role.rawValue,
            "specialist_category": categories,
            "show_in_hub": role == .specialist,
            "is_public": role == .specialist,
            "country_code": countryCode,
            "city": cityTrimmed,
            "registration_platform": "ios",
            "onboarding_completed_at": ISO8601DateFormatter().string(from: Date())
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            DiagnosticLogger.log(event: "onboarding_save_failed", extra: [
                "status": "\(http.statusCode)",
                "body": body
            ])
            throw NSError(
                domain: "Onboarding",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(loc.t("onb_save_failed")) (\(http.statusCode))"]
            )
        }
    }
}
