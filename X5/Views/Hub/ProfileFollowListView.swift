import SwiftUI

/// Экран «Подписчики / Подписки» — открывается тапом по счётчику
/// в своём профиле (ProfileView) и в чужом (UserProfileView).
/// Строки — те же `SpecialistRow`, что в Хабе; тап → публичный профиль.
struct ProfileFollowListView: View {
    let userId: String

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService

    @State private var kind: ProfileFollowListKind
    @State private var people: [HubSpecialist] = []
    @State private var nextOffset = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var loadFailed = false

    private let followService = ProfileFollowService()
    private let pageSize = 30
    private var contentWidth: CGFloat { min(UIScreen.main.bounds.width - 32, 390) }

    init(userId: String, initialKind: ProfileFollowListKind) {
        self.userId = userId
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                kindPicker
                content
            }
            .frame(maxWidth: contentWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable { await reload() }
        .background { X5Background() }
        .navigationTitle(loc.t(kind.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Переключение вкладки сбрасывает список и грузит первую страницу.
        .task(id: kind) { await reload() }
        // Подписался/отписался в открытом из списка профиле — обновляем,
        // чтобы при возврате список совпадал со счётчиком.
        .onReceive(
            NotificationCenter.default.publisher(for: .x5FollowStateDidChange)
        ) { note in
            let ids = [note.userInfo?["follower_id"], note.userInfo?["following_id"]]
                .compactMap { $0 as? String }
            guard ids.contains(where: { $0.caseInsensitiveCompare(userId) == .orderedSame }) else { return }
            Task { await reload() }
        }
    }

    // MARK: - Переключатель, как у вкладок профиля

    private var kindPicker: some View {
        HStack(spacing: 8) {
            ForEach(ProfileFollowListKind.allCases) { item in
                Button {
                    guard kind != item else { return }
                    X5Feedback.selection()
                    kind = item
                } label: {
                    Text(loc.t(item.titleKey))
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(kind == item ? Color.black : Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(kind == item ? Color.white : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Список

    @ViewBuilder
    private var content: some View {
        if people.isEmpty {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .padding(.top, 60)
            } else if loadFailed {
                VStack(spacing: 12) {
                    EmptyState(
                        systemImage: "wifi.exclamationmark",
                        title: loc.t("profile_follow_list_error"),
                        subtitle: ""
                    )
                    Button(loc.t("profile_follow_list_retry")) {
                        Task { await reload() }
                    }
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.top, 40)
            } else {
                EmptyState(
                    systemImage: "person.2",
                    title: loc.t(kind == .followers ? "profile_followers_empty" : "profile_following_empty"),
                    subtitle: ""
                )
                .padding(.top, 40)
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(people) { person in
                    NavigationLink {
                        UserProfileView(userId: person.id, fallback: person)
                    } label: {
                        SpecialistRow(person: person)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Догружаем следующую страницу, когда видна последняя строка.
                        if person.id == people.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Загрузка

    private func reload() async {
        people = []
        nextOffset = 0
        hasMore = true
        loadFailed = false
        isLoading = false
        await loadMore()
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        let requestedKind = kind
        let offset = nextOffset
        isLoading = true
        defer { isLoading = false }

        let token = await auth.freshAccessToken()
        do {
            let page = try await followService.loadList(
                requestedKind,
                userId: userId,
                accessToken: token,
                offset: offset,
                limit: pageSize
            )
            // Пока шёл запрос, могли переключить вкладку — старый ответ выбрасываем.
            guard requestedKind == kind, offset == nextOffset else { return }
            let known = Set(people.map { $0.id.lowercased() })
            // Заблокированных скрываем, как в Хабе и чатах (BlockList — локальный).
            people += page.people.filter {
                !known.contains($0.id.lowercased()) && !BlockList.contains($0.id)
            }
            nextOffset = offset + pageSize
            hasMore = page.hasMore
        } catch is CancellationError {
            return
        } catch {
            guard requestedKind == kind else { return }
            loadFailed = true
            hasMore = false
        }
    }
}
