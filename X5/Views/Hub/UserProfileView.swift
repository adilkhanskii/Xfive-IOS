import SwiftUI

/// Public profile — same hero language as the main profile, with public actions.
struct UserProfileView: View {
    let userId: String
    let fallback: HubSpecialist?

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var chats = ChatsService()

    @State private var profile: UserProfile?
    @State private var isLoading: Bool = false
    @State private var openingChat: Bool = false
    @State private var navigatingChat: ChatRoom?
    @State private var confirmBlock = false
    @State private var portfolioCount: Int = 0
    @State private var isFollowing = false
    @State private var followBusy = false
    @State private var followCounts: ProfileFollowCounts?
    @State private var isRefreshing = false

    private var baseURL: URL { X5Config.supabaseBaseURL }
    private var anonKey: String { X5Config.supabaseAnonKey }
    private let followService = ProfileFollowService()
    private var heroHeight: CGFloat { max(UIScreen.main.bounds.height * 0.78, 640) }
    private var profileContentWidth: CGFloat { min(UIScreen.main.bounds.width - 32, 390) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                coverHeader
                VStack(spacing: 16) {
                    publicBioCard
                    PortfolioGrid(userId: userId, canEdit: false)
                    publicSpecialistCard
                }
                .frame(maxWidth: profileContentWidth)
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 32)
        }
        .coordinateSpace(name: "publicProfileScroll")
        .refreshable { await refreshPublicProfile() }
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
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                }
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: profileShareText) {
                        Label(loc.t("common_share"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        reportUser()
                    } label: {
                        Label(loc.t("hub_report_user"), systemImage: "exclamationmark.bubble")
                    }
                    Button(role: .destructive) {
                        confirmBlock = true
                    } label: {
                        Label(loc.t("hub_block_user"), systemImage: "hand.raised.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                }
            }
        }
        .alert(loc.t("hub_block_user_title"), isPresented: $confirmBlock) {
            Button(loc.t("btn_cancel"), role: .cancel) {}
            Button(loc.t("hub_block_user"), role: .destructive) {
                BlockList.add(userId)
                dismiss()
            }
        } message: {
            Text(loc.t("hub_block_user_message"))
        }
        .task {
            chats.configureAccessTokenProvider(auth: auth)
            if isMe {
                NotificationCenter.default.post(name: .x5SwitchTab, object: nil, userInfo: ["tab": "profile"])
                dismiss()
                return
            }
            await load()
        }
        // Refresh server counts after returning from another app/device path.
        // A task keyed to ScenePhase has view-bound cancellation semantics.
        .task(id: scenePhase) {
            guard scenePhase == .active, !isMe else { return }
            await loadFollowState()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .x5FollowStateDidChange)
        ) { note in
            guard !followBusy, followEventAffectsDisplayedProfile(note) else { return }
            Task { await loadFollowState() }
        }
        .sheet(item: $navigatingChat) { chat in
            NavigationStack { ChatThreadView(chat: chat) }
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - Большая обложка с фото и именем

    private var coverHeader: some View {
        GeometryReader { proxy in
            let pull = max(proxy.frame(in: .named("publicProfileScroll")).minY, 0)
            let height = heroHeight + pull

            ZStack(alignment: .bottom) {
                CoverPhoto(urlString: profile?.avatar ?? fallback?.avatar,
                           name: profile?.name ?? fallback?.name)
                    .frame(width: proxy.size.width, height: height)
                    .clipped()

                LinearGradient(colors: [
                    Color.black.opacity(0.10),
                    Color.clear,
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.70)
                ], startPoint: .top, endPoint: .bottom)
                .frame(width: proxy.size.width, height: height)
                .allowsHitTesting(false)

                CoverPhoto(urlString: profile?.avatar ?? fallback?.avatar,
                           name: profile?.name ?? fallback?.name)
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
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.system(size: 42, weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
                        if (profile?.hasActiveVerifiedBadge ?? fallback?.hasActiveVerifiedBadge ?? false) {
                            VerifiedChip(size: 18)
                        }
                    }

                    if let nick = profile?.nickname ?? fallback?.nickname, !nick.isEmpty {
                        Text("@\(nick)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.66))
                    }
                    // Город и страна — как в своём профиле; пусто — строки нет.
                    if let location = CISLocations.profileLocationText(
                        city: profile?.city ?? fallback?.city,
                        countryCode: profile?.countryCode ?? fallback?.countryCode
                    ) {
                        Text("📍 \(location)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.66))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    actionRow

                    statsRow

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

    // MARK: - Кнопки Follow + message

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggleFollow() }
            } label: {
                HStack(spacing: 7) {
                    if followBusy {
                        ProgressView()
                            .tint(.black)
                            .scaleEffect(0.78)
                    } else {
                        Image(systemName: isFollowing ? "checkmark" : "plus")
                    }
                    Text(isFollowing ? loc.t("profile_following_action") : loc.t("profile_follow_action"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .layoutPriority(2)
            .disabled(isMe || followBusy || auth.accessToken == nil)

            Button(action: openChat) {
                HStack(spacing: 7) {
                    Image(systemName: openingChat ? "ellipsis" : "bubble.left.and.bubble.right.fill")
                    Text(loc.t("tab_chats"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.white.opacity(0.22))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(width: 112)
            .disabled(isMe || openingChat || auth.accessToken == nil)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 3 колонки статистики

    private var statsRow: some View {
        HStack(spacing: 8) {
            PublicStatBubble(value: followingValue, label: loc.t("profile_following"))
            PublicStatBubble(value: followersValue, label: loc.t("profile_followers"))
            PublicStatBubble(value: creationsValue, label: loc.t("profile_creations"))
        }
    }

    private var followingValue: String { followCounts.map { "\($0.following)" } ?? "—" }
    private var followersValue: String { followCounts.map { "\($0.followers)" } ?? "—" }
    private var creationsValue: String { "\(portfolioCount)" }

    @ViewBuilder
    private var publicBioCard: some View {
        if let bio = profile?.bio ?? fallback?.bio, !bio.isEmpty {
            Text(bio)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .x5ClearGlass(cornerRadius: 14, highlight: 0.10)
        }
    }

    @ViewBuilder
    private var publicSpecialistCard: some View {
        let cats = HubCategories.orderedIDs(
            from: profile?.specialistCategory ?? fallback?.specialistCategory ?? []
        )
        if !cats.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(loc.t("profile_specialist").uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Text(loc.t("profile_on_hub"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                FlowLayout(spacing: 6) {
                    ForEach(cats.prefix(6), id: \.self) { id in
                        Text(HubCategories.label(for: id, language: loc.current))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(14)
            .x5ClearGlass(cornerRadius: 14, highlight: 0.10)
        }
    }

    private var socialItems: [ProfileSocialLinkItem] {
        let links = profile?.socialLinks ?? fallback?.socialLinks
        guard let links, hasSocialLinks(links) else { return [] }
        return makeSocialItems(from: links)
    }

    private func hasSocialLinks(_ links: SocialLinks) -> Bool {
        !(links.telegram ?? "").isEmpty ||
        !(links.whatsapp ?? "").isEmpty ||
        !(links.instagram ?? "").isEmpty ||
        !(links.youtube ?? "").isEmpty ||
        !(links.tiktok ?? "").isEmpty ||
        !(links.linkedin ?? "").isEmpty ||
        !(links.facebook ?? "").isEmpty
    }

    // MARK: - Helpers

    private var displayName: String {
        profile?.displayName ?? fallback?.name ?? fallback?.nickname ?? "Xfive marketing"
    }

    private var isMe: Bool { auth.userId == userId }
    private var profileShareText: String { "Xfive marketing: \(displayName)" }

    private func openChat() {
        guard let me = auth.userId else { return }
        openingChat = true
        Task {
            guard let token = await auth.freshAccessToken() else {
                openingChat = false
                return
            }
            let chat = await chats.ensureChat(otherUserId: userId, currentUserId: me, taskId: nil, taskTitle: nil, accessToken: token)
            openingChat = false
            if let chat { navigatingChat = chat }
        }
    }

    private func reportUser() {
        let subject = "Report user \(userId)"
        let body = "Hi Xfive marketing team,\n\nI'd like to report this user. Please review their content.\n\nUser ID: \(userId)\n"
        let to = "appreview@x5studio.app"
        let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:\(to)?subject=\(s)&body=\(b)") {
            UIApplication.shared.open(url)
        }
    }

    private func refreshPublicProfile() async {
        isRefreshing = true
        await load(force: true)
        try? await Task.sleep(nanoseconds: 450_000_000)
        isRefreshing = false
    }

    private func load(force: Bool = false) async {
        guard force || !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userId)"),
            URLQueryItem(
                name: "select",
                value: "id,name,nickname,avatar,bio,services,plan,social_links,user_role,specialist_category,show_in_hub,is_public,signup_number,language,last_seen,is_verified,verified_until,country_code,city"
            )
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let rows = try? JSONDecoder().decode([UserProfile].self, from: data) {
            profile = rows.first
        }
        await loadPortfolioCount()
        await loadFollowState()
    }

    private func loadFollowState() async {
        let token = await auth.freshAccessToken()
        if let counts = try? await followService.loadCounts(
            userId: userId,
            accessToken: token
        ) {
            followCounts = counts
        }

        guard let me = auth.userId, me != userId, let token else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/followers"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "follower_id", value: "eq.\(me)"),
            URLQueryItem(name: "following_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "follower_id")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let rows = try? JSONDecoder().decode([[String: String]].self, from: data) {
            isFollowing = !rows.isEmpty
        }
    }

    private func toggleFollow() async {
        guard let me = auth.userId, me != userId, let token = await auth.freshAccessToken() else { return }
        followBusy = true
        defer { followBusy = false }
        if isFollowing {
            var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/followers"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "follower_id", value: "eq.\(me)"),
                URLQueryItem(name: "following_id", value: "eq.\(userId)")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "DELETE"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                guard status < 300 else { return }
                isFollowing = false
                if var counts = followCounts {
                    counts.followers = max(counts.followers - 1, 0)
                    followCounts = counts
                }
                postFollowStateChange(followerId: me)
                await loadFollowState()
            }
        } else {
            var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/followers"))
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["follower_id": me, "following_id": userId])
            if let (_, response) = try? await URLSession.shared.data(for: request) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                guard status < 300 else { return }
                isFollowing = true
                if var counts = followCounts {
                    counts.followers += 1
                    followCounts = counts
                }
                postFollowStateChange(followerId: me)
                await loadFollowState()
            }
        }
    }

    private func postFollowStateChange(followerId: String) {
        NotificationCenter.default.post(name: .x5FollowStateDidChange, object: nil, userInfo: [
            "follower_id": followerId,
            "following_id": userId
        ])
    }

    private func followEventAffectsDisplayedProfile(_ note: Notification) -> Bool {
        let followerId = note.userInfo?["follower_id"] as? String
        let followingId = note.userInfo?["following_id"] as? String
        return followerId?.caseInsensitiveCompare(userId) == .orderedSame ||
            followingId?.caseInsensitiveCompare(userId) == .orderedSame
    }

    private func loadPortfolioCount() async {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_items"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "moderation_status", value: "eq.approved"),
            URLQueryItem(name: "select", value: "id")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        if let (data, response) = try? await URLSession.shared.data(for: request) {
            if let http = response as? HTTPURLResponse,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last.map(String.init),
               let n = Int(total) {
                portfolioCount = n
            } else if let rows = try? JSONDecoder().decode([[String: String]].self, from: data) {
                portfolioCount = rows.count
            }
        }
    }

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

// MARK: - Subviews

private struct CoverPhoto: View {
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

private struct PublicStatBubble: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .x5ClearGlass(cornerRadius: 14, highlight: 0.10)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW { x = 0; y += lineH + spacing; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sz.width, height: sz.height))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
