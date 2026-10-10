import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var subscription: Subscription
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var showsDoneButton: Bool = true

    @State private var showingStore = false
    @State private var showingVerified = false
    @State private var showingSettings = false
    @State private var showingEdit = false
    // Галерея — SystemPhotoPicker на корне экрана: SwiftUI-шная после Face ID
    // закрывалась и открывалась по кругу (Адильхан 10.10).
    @State private var showingAvatarPicker = false
    @State private var uploadingAvatar = false
    @State private var avatarError: String?
    @State private var isRefreshing = false
    @State private var showInHubToggle = false
    @State private var savingShowInHub = false
    @State private var selectedSection: ProfileSection = .overview
    @State private var followCounts: ProfileFollowCounts?
    /// Счётчики обновляем только после настоящего фона, не после «неактивно»:
    /// галерея и Face ID на секунду делают приложение неактивным, и перерисовка
    /// профиля перезапускала галерею при выборе обложки (Адильхан 10.10).
    @State private var wasInBackground = false

    private let followService = ProfileFollowService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero

                    VStack(spacing: 16) {
                        sectionPicker
                        selectedSectionContent
                    }
                    .frame(maxWidth: profileContentWidth)
                    .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 32)
            }
            .coordinateSpace(name: "profileScroll")
            .scrollIndicators(.hidden)
            .refreshable { await refreshProfile() }
            .background { X5Background() }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 58)
                }
            }
            .navigationTitle(loc.t("profile_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if showsDoneButton {
                        Button(loc.t("btn_done")) {
                            X5Feedback.selection()
                            dismiss()
                        }
                    } else {
                        Button { showingAvatarPicker = true } label: {
                            Image(systemName: uploadingAvatar ? "hourglass" : "camera.fill")
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .disabled(uploadingAvatar)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        X5Feedback.impact()
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingStore) { PaywallView() }
            .sheet(isPresented: $showingVerified) { VerifiedBadgeView() }
            .sheet(isPresented: $showingEdit) { EditProfileView() }
            .alert("Фото не сохранилось", isPresented: Binding(
                get: { avatarError != nil },
                set: { if !$0 { avatarError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(avatarError ?? "")
            }
            .x5SinglePhotoPicker(isPresented: $showingAvatarPicker) { provider in
                X5Feedback.selection()
                Task { await uploadAvatar(provider) }
            }
            .onChange(of: currentUser.profile?.showInHub) { value in
                if !savingShowInHub {
                    showInHubToggle = value ?? false
                }
            }
            .onAppear { showInHubToggle = currentUser.profile?.showInHub ?? false }
            .task(id: currentUser.profile?.id) {
                await refreshFollowCounts()
            }
            // Cross-device follow changes do not emit this process's local
            // notification. Refresh whenever the app returns to the foreground;
            // SwiftUI cancels this task automatically when the view disappears.
            .task(id: scenePhase) {
                if scenePhase == .background { wasInBackground = true }
                guard scenePhase == .active, wasInBackground else { return }
                wasInBackground = false
                await refreshFollowCounts()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .x5FollowStateDidChange)
            ) { note in
                guard followEventAffectsCurrentProfile(note) else { return }
                Task { await refreshFollowCounts() }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        GeometryReader { proxy in
            let pull = max(proxy.frame(in: .named("profileScroll")).minY, 0)
            let height = heroHeight + pull

            ZStack(alignment: .bottom) {
                ProfileCoverPhoto(urlString: currentUser.profile?.avatar,
                                  name: displayName)
                    .frame(width: proxy.size.width, height: height)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.10),
                        Color.clear,
                        Color.black.opacity(0.12),
                        Color.black.opacity(0.70)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: height)
                .allowsHitTesting(false)

                ProfileCoverPhoto(urlString: currentUser.profile?.avatar,
                                  name: displayName)
                    .frame(width: proxy.size.width, height: height)
                    .clipped()
                    .blur(radius: 22)
                    .scaleEffect(1.04)
                    .overlay(Color.black.opacity(0.10))
                    .mask(
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.72), .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 300)
                        }
                    )
                    .allowsHitTesting(false)

                ProfileHeroBottomFade()
                    .frame(width: proxy.size.width, height: 300)
                    .position(x: proxy.size.width / 2, y: height - 150)

                VStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 42, weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 4)
                        if currentUser.profile?.hasActiveVerifiedBadge == true {
                            VerifiedChip(size: 18)
                        }
                    }
                    if !handleText.isEmpty {
                        Text(handleText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.66))
                    }
                    // Город и страна из «Редактировать профиль» (CISCityPicker); пусто — строки нет.
                    if let location = CISLocations.profileLocationText(
                        city: currentUser.profile?.city,
                        countryCode: currentUser.profile?.countryCode
                    ) {
                        Text("📍 \(location)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.66))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    if shouldShowHubVisibilityToggle {
                        hubVisibilityToggle
                    }

                    Button {
                        X5Feedback.impact()
                        showingEdit = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pencil")
                            Text(loc.t("profile_edit"))
                        }
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.black)

                    heroStatsRow

                    ProfileSocialLinksStrip(items: socialItems)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: profileContentWidth)
                .frame(maxWidth: .infinity)
            }
            .frame(width: proxy.size.width, height: height)
            .offset(y: -pull)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
    }

    private var sectionPicker: some View {
        Picker("", selection: $selectedSection) {
            ForEach(ProfileSection.allCases) { section in
                Text(section.title(loc)).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(4)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .overview:
            overviewSection
        case .works:
            worksSection
        case .saved:
            savedWorksSection
        }
    }

    private var overviewSection: some View {
        VStack(spacing: 16) {
            storeCard
            myTasksCard
            if let bio = currentUser.profile?.bio, !bio.isEmpty {
                BioCard(text: bio)
            }
            if !hasSpecialistCategories {
                becomeSpecialistCard
            }
            if let cats = currentUser.profile?.specialistCategory, !cats.isEmpty {
                specialistCard(cats: HubCategories.orderedIDs(from: cats))
            }
            if !(currentUser.profile?.hasActiveVerifiedBadge ?? false) {
                verifiedCard
            }
        }
    }

    @ViewBuilder
    private var worksSection: some View {
        if let uid = currentUser.profile?.id {
            PortfolioGrid(userId: uid, canEdit: true)
        }
    }

    @ViewBuilder
    private var savedWorksSection: some View {
        if let uid = currentUser.profile?.id {
            PortfolioGrid(userId: uid, canEdit: false, mode: .saved)
        }
    }

    private func uploadAvatar(_ provider: NSItemProvider) async {
        guard let profileOperation = currentUser.operationContext() else { return }
        guard let token = await auth.freshAccessToken() else {
            avatarError = "Сессия устарела. Войди заново и попробуй еще раз."
            return
        }
        uploadingAvatar = true
        defer { uploadingAvatar = false }
        if let data = try? await PickedPhotoLoader.loadData(from: provider),
           let image = UIImage(data: data),
           let jpeg = image.jpegData(compressionQuality: 0.85) {
            let url = await currentUser.uploadAvatar(jpeg, accessToken: token, operation: profileOperation)
            if url == nil {
                X5Feedback.error()
                avatarError = "Сервер не принял фото. Проверь доступ к аккаунту и попробуй еще раз."
            } else {
                X5Feedback.success()
            }
        } else {
            X5Feedback.error()
            avatarError = "Не удалось прочитать фото."
        }
    }

    // MARK: - Stats

    private var heroStatsRow: some View {
        HStack(spacing: 8) {
            StatBubble(value: "\(currentUser.profile?.credits ?? 0)", label: loc.t("profile_credits"))
            // Счётчики кликабельные: тап открывает список людей (просьба
            // Адильхана 07.10 — «смотреть подписчиков и подписки»).
            followListLink(.followers) {
                StatBubble(
                    value: followCounts?.followers.description ?? "—",
                    label: loc.t("profile_followers")
                )
            }
            followListLink(.following) {
                StatBubble(
                    value: followCounts?.following.description ?? "—",
                    label: loc.t("profile_following")
                )
            }
        }
    }

    @ViewBuilder
    private func followListLink<Content: View>(
        _ kind: ProfileFollowListKind,
        @ViewBuilder label: () -> Content
    ) -> some View {
        if let uid = auth.userId ?? currentUser.profile?.id {
            NavigationLink {
                ProfileFollowListView(userId: uid, initialKind: kind)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else {
            label()
        }
    }

    private var hubVisibilityToggle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("edit_show_in_hub"))
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.white)
                Text(loc.t("edit_public_profile"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.56))
            }
            Spacer()
            if savingShowInHub {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
            }
        Toggle("", isOn: Binding(
                get: { showInHubToggle },
                set: { value in
                    guard value != showInHubToggle else { return }
                    showInHubToggle = value
                    X5Feedback.selection()
                    Task { await updateHubVisibility(value) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color.accentColor)
            .disabled(savingShowInHub)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.12)
    }

    private var hasSpecialistCategories: Bool {
        currentUser.profile?.specialistCategory?.isEmpty == false
    }

    private var shouldShowHubVisibilityToggle: Bool {
        hasSpecialistCategories
    }

    private var heroHeight: CGFloat {
        max(UIScreen.main.bounds.height * 0.78, 640)
    }

    private var profileContentWidth: CGFloat {
        min(UIScreen.main.bounds.width - 32, 390)
    }

    private func refreshProfile() async {
        isRefreshing = true
        guard let uid = auth.userId, let token = await auth.freshAccessToken() else {
            isRefreshing = false
            return
        }
        await currentUser.load(userId: uid, accessToken: token)
        await refreshFollowCounts(accessToken: token)
        showInHubToggle = currentUser.profile?.showInHub ?? false
        subscription.sync(from: currentUser.profile)
        try? await Task.sleep(nanoseconds: 450_000_000)
        isRefreshing = false
    }

    private func refreshFollowCounts(accessToken: String? = nil) async {
        guard let uid = auth.userId ?? currentUser.profile?.id else { return }
        let token: String?
        if let accessToken {
            token = accessToken
        } else {
            token = await auth.freshAccessToken()
        }
        if let counts = try? await followService.loadCounts(
            userId: uid,
            accessToken: token
        ) {
            followCounts = counts
        }
    }

    private func followEventAffectsCurrentProfile(_ note: Notification) -> Bool {
        guard let uid = auth.userId ?? currentUser.profile?.id else { return false }
        let followerId = note.userInfo?["follower_id"] as? String
        let followingId = note.userInfo?["following_id"] as? String
        return followerId?.caseInsensitiveCompare(uid) == .orderedSame ||
            followingId?.caseInsensitiveCompare(uid) == .orderedSame
    }

    private func updateHubVisibility(_ value: Bool) async {
        guard let profileOperation = currentUser.operationContext() else { return }
        guard let token = await auth.freshAccessToken() else {
            X5Feedback.error()
            showInHubToggle = currentUser.profile?.showInHub ?? false
            return
        }
        savingShowInHub = true
        defer { savingShowInHub = false }

        guard hasSpecialistCategories else {
            await currentUser.patchMany(["show_in_hub": AnyEncodable(false)], accessToken: token, operation: profileOperation)
            showInHubToggle = false
            X5Feedback.selection()
            return
        }

        var fields: [String: AnyEncodable] = [
            "show_in_hub": AnyEncodable(value)
        ]
        if value {
            fields["user_role"] = AnyEncodable("specialist")
            fields["is_public"] = AnyEncodable(true)
        }
        guard await currentUser.patchMany(fields, accessToken: token, operation: profileOperation) else {
            showInHubToggle = currentUser.profile?.showInHub ?? false
            X5Feedback.error()
            return
        }
        showInHubToggle = currentUser.profile?.showInHub ?? value
        X5Feedback.success()
    }

    private var displayName: String {
        let raw = currentUser.profile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw,
           !raw.isEmpty,
           raw != "User",
           raw.replacingOccurrences(of: " ", with: "").lowercased() != "xfivemarketing" {
            return raw
        }
        if let emailName = emailPrefix { return emailName }
        return "Xfive marketing"
    }

    private var handleText: String {
        if let nick = currentUser.profile?.nickname, !nick.isEmpty { return "@\(nick)" }
        if let emailName = emailPrefix { return "@\(emailName.lowercased())" }
        return ""
    }

    private var emailPrefix: String? {
        guard let email = auth.userEmail, let prefix = email.split(separator: "@").first else { return nil }
        let cleaned = String(prefix).replacingOccurrences(of: ".", with: " ")
        return cleaned.isEmpty ? nil : cleaned.capitalized
    }

    // MARK: - Credit store

    private var myTasksCard: some View {
        NavigationLink {
            MyTasksView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("my_tasks_title"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(loc.t("my_tasks_profile_subtitle"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(14)
            .x5ClearGlass(cornerRadius: 16, highlight: 0.12)
        }
        .buttonStyle(.plain)
    }

    private var storeCard: some View {
        Button {
            showingStore = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("profile_store_title"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(String(
                        format: loc.t("profile_store_subtitle"),
                        currentUser.profile?.credits ?? 0
                    ))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.4))
            }
            .padding(14)
            .x5ClearGlass(cornerRadius: 16, highlight: 0.12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Become a specialist

    private var becomeSpecialistCard: some View {
        Button {
            showingEdit = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("profile_become_specialist_title"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(loc.t("profile_become_specialist_sub"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(14)
            .x5ClearGlass(cornerRadius: 16, highlight: 0.12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Verified upsell

    private var verifiedCard: some View {
        Button {
            showingVerified = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [Color.accentColor, .blue],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("profile_get_verified")).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text(loc.t("profile_verified_sub"))
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.4))
            }
            .padding(14)
            .x5ClearGlass(cornerRadius: 16, highlight: 0.12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Social

    private var socialItems: [ProfileSocialLinkItem] {
        guard let links = currentUser.profile?.socialLinks else { return [] }
        return makeSocialItems(from: links)
    }

    private func specialistCard(cats: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc.t("profile_specialist").uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(currentUser.profile?.showInHub == true ? loc.t("profile_on_hub") : loc.t("profile_hidden"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(currentUser.profile?.showInHub == true ? .accentColor : .white.opacity(0.5))
            }
            HStack(spacing: 6) {
                ForEach(cats.prefix(3), id: \.self) { id in
                    Text(HubCategories.label(for: id, language: loc.current))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 14, highlight: 0.10)
    }

    // MARK: - Helpers

    private func makeSocialItems(from links: SocialLinks) -> [ProfileSocialLinkItem] {
        [
            socialItem(id: "instagram", label: "Instagram", brand: .instagram, raw: links.instagram, fallbackHost: "https://instagram.com/"),
            socialItem(id: "tiktok", label: "TikTok", brand: .tiktok, raw: links.tiktok, fallbackHost: "https://www.tiktok.com/@"),
            socialItem(id: "telegram", label: "Telegram", brand: .telegram, raw: links.telegram, fallbackHost: "https://t.me/"),
            socialItem(id: "whatsapp", label: "WhatsApp", brand: .whatsapp, raw: links.whatsapp, fallbackHost: "https://wa.me/", digitsOnly: true),
            socialItem(id: "youtube", label: "YouTube", brand: .youtube, raw: links.youtube, fallbackHost: "https://youtube.com/"),
            socialItem(id: "linkedin", label: "LinkedIn", brand: .linkedin, raw: links.linkedin, fallbackHost: "https://linkedin.com/in/"),
            socialItem(id: "facebook", label: "Facebook", brand: .facebook, raw: links.facebook, fallbackHost: "https://facebook.com/")
        ].compactMap { $0 }
    }

    private func socialItem(id: String, label: String, brand: SocialBrand, raw: String?, fallbackHost: String, digitsOnly: Bool = false) -> ProfileSocialLinkItem? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("http"), let url = URL(string: value) {
            return ProfileSocialLinkItem(id: id, label: label, brand: brand, url: url)
        }
        let cleaned = digitsOnly ? value.filter("0123456789".contains) : value.replacingOccurrences(of: "@", with: "")
        guard !cleaned.isEmpty else { return nil }
        return ProfileSocialLinkItem(id: id, label: label, brand: brand, url: URL(string: fallbackHost + cleaned))
    }
}

struct ProfileSocialLinkItem: Identifiable, Hashable {
    let id: String
    let label: String
    let brand: SocialBrand
    let url: URL?
}

struct ProfileSocialLinksStrip: View {
    let items: [ProfileSocialLinkItem]

    var body: some View {
        if !items.isEmpty {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                if let url = item.url {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    SocialBrandIcon(item.brand, size: 16)
                                    Text(item.label)
                                        .font(.system(size: 12, weight: .bold))
                                        .lineLimit(1)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .x5ClearGlass(cornerRadius: 19, highlight: 0.10)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.url == nil)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(minWidth: proxy.size.width, alignment: .center)
                }
            }
            .frame(height: 42)
        }
    }
}

private enum ProfileSection: String, CaseIterable, Identifiable {
    case overview
    case works
    case saved

    var id: String { rawValue }

    @MainActor
    func title(_ loc: LocalizationService) -> String {
        switch self {
        case .overview: return loc.t("profile_tab_overview")
        case .works: return loc.t("profile_tab_works")
        case .saved: return "Сохранённые"
        }
    }
}

// MARK: - Components

private struct StatBubble: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .x5ClearGlass(cornerRadius: 14, highlight: 0.10)
    }
}

private struct BioCard: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .x5ClearGlass(cornerRadius: 14, highlight: 0.10)
    }
}

// MARK: - Profile cover helpers

private struct ProfileCoverPhoto: View {
    let urlString: String?
    let name: String?

    var body: some View {
        Group {
            if let s = urlString, !s.isEmpty, let url = URL(string: s) {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.20, green: 0.45, blue: 0.85),
                Color(red: 0.05, green: 0.12, blue: 0.40)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: 80, weight: .heavy))
                .foregroundColor(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initials: String {
        let parts = (name ?? "?").split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

private struct ProfileStatCell: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProfileStatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 28)
    }
}
