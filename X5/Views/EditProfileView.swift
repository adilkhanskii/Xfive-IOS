import SwiftUI

struct EditProfileView: View {
    var activateSpecialistOnOpen: Bool = false

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    // Mirror of profile fields, mutable
    @State private var name: String = ""
    @State private var nickname: String = ""
    @State private var bio: String = ""
    @State private var instagram: String = ""
    @State private var telegram: String = ""
    @State private var whatsapp: String = ""
    @State private var tiktok: String = ""
    @State private var youtube: String = ""
    @State private var linkedin: String = ""
    @State private var facebook: String = ""
    @State private var pickedCategories: Set<String> = []
    @State private var showInHub: Bool = false
    @State private var countryCode: String = "KZ"
    @State private var city: String = ""

    @State private var saving = false
    @State private var errorMessage: String?
    @State private var didPopulate = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(loc.t("edit_specialist"))) {
                    NavigationLink {
                        CategoriesPicker(selected: $pickedCategories)
                    } label: {
                        HStack {
                            Text(loc.t("edit_categories"))
                            Spacer()
                            Text(pickedCategories.isEmpty ? "—" : "\(pickedCategories.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text(loc.t("edit_about_section"))) {
                    TextField(loc.t("edit_name_placeholder"), text: $name)
                        .textInputAutocapitalization(.words)
                    TextField(loc.t("edit_nickname_placeholder"), text: $nickname)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                        .onChange(of: nickname) { value in
                            nickname = value.lowercased()
                                .filter { "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }
                        }
                    TextField(loc.t("edit_bio_placeholder"), text: $bio, axis: .vertical)
                        .lineLimit(2...5)
                    Text("\(bio.count) / 500")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section(header: Text(loc.t("task_location_section"))) {
                    Picker(loc.t("onb_country"), selection: $countryCode) {
                        ForEach(CISLocations.countries, id: \.code) { country in
                            Text(country.name).tag(country.code)
                        }
                    }
                    CISCityPickerButton(city: $city, countryCode: countryCode)
                }

                Section(header: Text(loc.t("edit_social")),
                        footer: Text(loc.t("edit_social_footer")).font(.caption)) {
                    socialRow(brand: .instagram, name: "Instagram", text: $instagram, placeholder: "@username")
                    socialRow(brand: .telegram, name: "Telegram", text: $telegram, placeholder: "@username")
                    socialRow(brand: .whatsapp, name: "WhatsApp", text: $whatsapp, placeholder: "+7…")
                    socialRow(brand: .tiktok, name: "TikTok", text: $tiktok, placeholder: "@username")
                    socialRow(brand: .youtube, name: "YouTube", text: $youtube, placeholder: "@channel")
                    socialRow(brand: .linkedin, name: "LinkedIn", text: $linkedin, placeholder: "linkedin.com/in/…")
                    socialRow(brand: .facebook, name: "Facebook", text: $facebook, placeholder: "facebook.com/…")
                }

                if let err = errorMessage {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle(loc.t("edit_profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("btn_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        X5Feedback.impact()
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text(loc.t("common_save")).bold() }
                    }
                    .disabled(saving || !isValid)
                }
            }
            .onAppear { populateIfNeeded() }
            .onChange(of: currentUser.profile?.id) { _ in populateIfNeeded() }
            .onChange(of: countryCode) { newCountry in
                if didPopulate && newCountry != currentUser.profile?.countryCode { city = "" }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func socialField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .autocapitalization(.none)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
    }

    private func socialRow(brand: SocialBrand, name: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            SocialBrandIcon(brand, size: 24)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                TextField(placeholder, text: text)
                    .autocapitalization(.none)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .font(.system(size: 14))
            }
        }
    }

    private var isValid: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanName.count < 2 || cleanName.lowercased() == "user" || cleanName.lowercased() == "x5" { return false }
        if cleanNickname.range(of: "^[a-z0-9_]{3,}$", options: .regularExpression) == nil { return false }
        let cleanCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return bio.count <= 500 && !countryCode.isEmpty && cleanCity.count >= 2
    }

    private func populateIfNeeded() {
        guard !didPopulate else { return }
        populate()
    }

    private func populate() {
        showInHub = activateSpecialistOnOpen
        guard let p = currentUser.profile else { return }
        didPopulate = true
        name = p.name ?? ""
        nickname = p.nickname ?? ""
        bio = p.bio ?? ""
        countryCode = p.countryCode ?? "KZ"
        city = p.city ?? ""
        if let s = p.socialLinks {
            instagram = s.instagram ?? ""
            telegram = s.telegram ?? ""
            whatsapp = s.whatsapp ?? ""
            tiktok = s.tiktok ?? ""
            youtube = s.youtube ?? ""
            linkedin = s.linkedin ?? ""
            facebook = s.facebook ?? ""
        }
        pickedCategories = Set(p.specialistCategory ?? [])
        showInHub = activateSpecialistOnOpen || (p.showInHub ?? false)
    }

    private func save() async {
        guard let profileOperation = currentUser.operationContext() else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        guard let token = await auth.freshAccessToken() else {
            errorMessage = loc.t("onb_session_expired")
            return
        }

        let socials: [String: String?] = [
            "instagram": nilIfEmpty(instagram),
            "telegram":  nilIfEmpty(telegram),
            "whatsapp":  nilIfEmpty(whatsapp),
            "tiktok":    nilIfEmpty(tiktok),
            "youtube":   nilIfEmpty(youtube),
            "linkedin":  nilIfEmpty(linkedin),
            "facebook":  nilIfEmpty(facebook)
        ]
        let cleanCategories = Array(pickedCategories)
        let cleanShowInHub = showInHub && !cleanCategories.isEmpty

        var fields: [String: AnyEncodable] = [
            "name": AnyEncodable(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "nickname": AnyEncodable(nickname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            "bio": AnyEncodable(nilIfEmpty(bio)),
            "social_links": AnyEncodable(socials),
            "country_code": AnyEncodable(countryCode),
            "city": AnyEncodable(city.trimmingCharacters(in: .whitespacesAndNewlines)),
            "specialist_category": AnyEncodable(cleanCategories),
            "show_in_hub": AnyEncodable(cleanShowInHub)
        ]
        // Auto-set role only after actual specialist categories are selected.
        if cleanShowInHub {
            fields["user_role"] = AnyEncodable("specialist")
            fields["is_public"] = AnyEncodable(true)
        }
        guard await currentUser.patchMany(fields, accessToken: token, operation: profileOperation) else {
            errorMessage = currentUser.error ?? loc.t("onb_save_failed")
            return
        }
        X5Feedback.success()
        dismiss()
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CategoriesPicker: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: Set<String>
    private let maxPickedCategories = 8

    var body: some View {
        List {
            ForEach(HubCategories.all) { cat in
                Toggle(isOn: categoryBinding(for: cat.id)) {
                    Label(HubCategories.label(for: cat.id, language: loc.current),
                          systemImage: HubCategories.symbol(for: cat.id))
                        .foregroundColor(.white)
                }
                .tint(.accentColor)
                .disabled(!selected.contains(cat.id) && selected.count >= maxPickedCategories)
                .listRowBackground(selected.contains(cat.id) ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.04, green: 0.05, blue: 0.10))
        .navigationTitle(loc.t("edit_categories"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(loc.t("btn_done")) {
                    X5Feedback.selection()
                    dismiss()
                }
            }
        }
    }

    private func categoryBinding(for id: String) -> Binding<Bool> {
        Binding {
            selected.contains(id)
        } set: { isSelected in
            X5Feedback.selection()
            if isSelected {
                if selected.count < maxPickedCategories {
                    selected.insert(id)
                }
            } else {
                selected.remove(id)
            }
        }
    }
}
