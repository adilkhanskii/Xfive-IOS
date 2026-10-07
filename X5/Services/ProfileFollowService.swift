import Foundation

struct ProfileFollowCounts: Equatable, Sendable {
    var followers: Int
    var following: Int
}

enum ProfileFollowServiceError: Error, Equatable {
    case invalidRequest
    case http(statusCode: Int)
}

struct ProfileFollowService {
    private enum Dimension: String {
        // A profile's followers are rows where that profile is being followed.
        case followers = "following_id"
        // A profile's following are rows created by that profile.
        case following = "follower_id"
    }

    private struct FollowRow: Decodable {
        let followerId: String

        enum CodingKeys: String, CodingKey {
            case followerId = "follower_id"
        }
    }

    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
    }

    func loadCounts(
        userId: String,
        accessToken: String?
    ) async throws -> ProfileFollowCounts {
        let followers = try await count(
            .followers,
            userId: userId,
            accessToken: accessToken
        )
        let following = try await count(
            .following,
            userId: userId,
            accessToken: accessToken
        )
        return ProfileFollowCounts(followers: followers, following: following)
    }

    private func count(
        _ dimension: Dimension,
        userId: String,
        accessToken: String?
    ) async throws -> Int {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/followers"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProfileFollowServiceError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: dimension.rawValue, value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "follower_id")
        ]
        guard let url = components.url else {
            throw ProfileFollowServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        if let accessToken, !accessToken.isEmpty {
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ProfileFollowServiceError.http(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.map(String.init),
           let count = Int(total) {
            return count
        }

        return (try? JSONDecoder().decode([FollowRow].self, from: data).count) ?? 0
    }
}

// MARK: - Списки «Подписчики» / «Подписки»

/// Какой список открыт на экране профиля.
enum ProfileFollowListKind: String, CaseIterable, Identifiable, Sendable {
    case followers
    case following

    var id: String { rawValue }

    /// По какой колонке фильтруем строки `followers` для профиля userId.
    /// Подписчики профиля — строки, где на него подписались (following_id),
    /// подписки — строки, которые создал он сам (follower_id).
    var filterColumn: String {
        switch self {
        case .followers: return "following_id"
        case .following: return "follower_id"
        }
    }

    /// Колонка со «вторым» человеком — его и показываем в списке.
    var personColumn: String {
        switch self {
        case .followers: return "follower_id"
        case .following: return "following_id"
        }
    }

    var titleKey: String {
        switch self {
        case .followers: return "profile_followers"
        case .following: return "profile_following"
        }
    }
}

struct ProfileFollowPage: Equatable {
    let people: [HubSpecialist]
    /// true — сервер вернул полную страницу, значит дальше может быть ещё.
    let hasMore: Bool
}

extension ProfileFollowService {
    /// Поля профиля, как у строк Хаба: тот же `HubSpecialist` и та же строка
    /// `SpecialistRow`, чтобы список выглядел как соседние экраны.
    static let listProfileSelect =
        "id,name,nickname,avatar,bio,specialist_category,plan,services,social_links,country_code,city,is_verified,verified_until,subscription_end_date"

    private struct FollowPairRow: Decodable {
        let followerId: String
        let followingId: String

        enum CodingKeys: String, CodingKey {
            case followerId = "follower_id"
            case followingId = "following_id"
        }
    }

    /// Одна страница списка. Два запроса, потому что у `followers` нет
    /// внешнего ключа на `profiles` (PostgREST не умеет embed без FK):
    /// 1) id людей из `followers` (новые сверху), 2) их профили через `id=in.(…)`.
    /// Порядок берём из первого запроса; удалённые профили просто пропускаем.
    func loadList(
        _ kind: ProfileFollowListKind,
        userId: String,
        accessToken: String?,
        offset: Int = 0,
        limit: Int = 30
    ) async throws -> ProfileFollowPage {
        let pairs: [FollowPairRow] = try await get(
            "rest/v1/followers",
            query: [
                URLQueryItem(name: kind.filterColumn, value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "follower_id,following_id"),
                // id — второй ключ сортировки, чтобы страницы не «прыгали»
                // при одинаковом created_at.
                URLQueryItem(name: "order", value: "created_at.desc,id.desc"),
                URLQueryItem(name: "offset", value: "\(max(offset, 0))"),
                URLQueryItem(name: "limit", value: "\(max(limit, 1))")
            ],
            accessToken: accessToken
        )
        let hasMore = pairs.count >= max(limit, 1)

        var seen = Set<String>()
        let ids = pairs
            .map { kind == .followers ? $0.followerId : $0.followingId }
            .filter { seen.insert($0.lowercased()).inserted }
        guard !ids.isEmpty else {
            return ProfileFollowPage(people: [], hasMore: false)
        }

        let profiles: [HubSpecialist] = try await get(
            "rest/v1/profiles",
            query: [
                URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
                URLQueryItem(name: "select", value: Self.listProfileSelect)
            ],
            accessToken: accessToken
        )
        let byId = Dictionary(
            profiles.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let people = ids.compactMap { byId[$0.lowercased()] }
        return ProfileFollowPage(people: people, hasMore: hasMore)
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem],
        accessToken: String?
    ) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProfileFollowServiceError.invalidRequest
        }
        components.queryItems = query
        guard let url = components.url else {
            throw ProfileFollowServiceError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ProfileFollowServiceError.http(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Notification.Name {
    static let x5FollowStateDidChange = Notification.Name("x5.follow.state.did_change")
}
