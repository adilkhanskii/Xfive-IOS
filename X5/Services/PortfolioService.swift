import Foundation

struct PortfolioItem: Codable, Identifiable, Equatable {
    let id: String
    let userId: String
    var type: String           // image | video | project
    var title: String?
    var description: String?
    var mediaUrl: String?
    var thumbnailUrl: String?
    var link: String?
    var sortOrder: Int?
    var createdAt: String?
    var moderationStatusRaw: String?
    var moderationReason: String?
    var moderationRevision: Int64?
    /// Short-lived display URLs are deliberately never encoded back into the
    /// database. `mediaUrl` and `thumbnailUrl` remain stable object IDs.
    var signedMediaUrl: String? = nil
    var signedThumbnailUrl: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, title, description, link
        case userId = "user_id"
        case mediaUrl = "media_url"
        case thumbnailUrl = "thumbnail_url"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case moderationStatusRaw = "moderation_status"
        case moderationReason = "moderation_reason"
        case moderationRevision = "moderation_revision"
    }

    var displayMediaUrl: String? { signedMediaUrl }
    var displayThumbnailUrl: String? { signedThumbnailUrl ?? signedMediaUrl }

    /// У видео есть обложка (новое превью «…-cover.jpg»), а не только сетка кадров.
    var hasVideoCover: Bool {
        type == "video" && (thumbnailUrl?.hasSuffix(PortfolioMediaPolicy.videoCoverSuffix) ?? false)
    }

    var moderationStatus: String {
        moderationStatusRaw ?? "approved"
    }

    var needsModerationBadge: Bool {
        moderationStatus != "approved"
    }

    var moderationBadgeTitle: String {
        switch moderationStatus {
        case "rejected": return "Отклонено"
        case "pending", "manual_review", "failed":
            return "Автопроверка повторится"
        default: return "Автопроверка пройдена"
        }
    }
}

enum PortfolioMediaPolicy {
    static let bucket = "portfolio"
    /// Превью видео с обложкой: «…-cover.jpg» = сверху обложка 3:4, снизу сетка
    /// кадров для автопроверки (одна картинка в существующей колонке thumbnail_url,
    /// без миграции). Старые превью без суффикса — только сетка кадров.
    static let videoCoverSuffix = "-cover.jpg"
    static let canonicalPublicPathPrefix = "/storage/v1/object/public/\(bucket)/"
    static let canonicalPrivatePathPrefix = "/storage/v1/object/\(bucket)/"

    static func objectPath(
        fromCanonicalURL rawValue: String,
        expectedHost: String = "afwznqjpshybmqhlewmy.supabase.co"
    ) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == rawValue,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == expectedHost.lowercased(),
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        let encodedPath = components.percentEncodedPath
        let prefix: String
        if encodedPath.hasPrefix(canonicalPublicPathPrefix) {
            prefix = canonicalPublicPathPrefix
        } else if encodedPath.hasPrefix(canonicalPrivatePathPrefix) {
            prefix = canonicalPrivatePathPrefix
        } else {
            return nil
        }

        let encodedObjectPath = String(encodedPath.dropFirst(prefix.count))
        guard let objectPath = encodedObjectPath.removingPercentEncoding,
              objectPath == encodedObjectPath,
              objectPath.count <= 1_024
        else { return nil }

        let parts = objectPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              isSafeOwner(parts[0]),
              parts.count != 3 || parts[1] == "thumbnails",
              isSafeFilename(parts.last ?? "")
        else { return nil }
        return objectPath
    }

    private static func isSafeOwner(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.count <= 200 && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !value.isEmpty
            && value.count <= 255
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct PortfolioLikeState: Equatable {
    let isLiked: Bool
    let count: Int
}

struct PortfolioSaveState: Equatable {
    let isSaved: Bool
}

struct PortfolioAuthor: Codable, Equatable {
    let id: String
    let name: String?
    let avatar: String?
    let nickname: String?
}

/// Строка `public.portfolio_comments` — таблица, которая реально есть в проде
/// (её создавал сайт, mig_portfolio.mjs; RLS: читать всем, писать/удалять своё).
/// Зачем: iOS ходил в `portfolio_item_comments`, которой в проде НЕТ (см.
/// docs/MIGRATION-HISTORY-2026-10-02.md) → комментарии молча не работали.
/// Имени и аватара в таблице нет — подставляем из `profiles` после загрузки,
/// поэтому email автора больше нигде не хранится и не показывается.
struct PortfolioComment: Codable, Identifiable, Equatable {
    let id: String
    let itemId: String
    let userId: String
    var userName: String? = nil
    var userAvatar: String? = nil
    let text: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, text
        case itemId = "portfolio_id"
        case userId = "user_id"
        case createdAt = "created_at"
    }
}

@MainActor
final class PortfolioService: ObservableObject {
    @Published private(set) var items: [PortfolioItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?
    @Published private(set) var authors: [String: PortfolioAuthor] = [:]

    private let baseURL: URL
    private let anonKey: String
    private let functionsBaseURL: URL
    private let session: URLSession
    private let signedMediaCacheTTL: TimeInterval
    private let signedMediaLifetimeSeconds = 600

    private struct CachedSignedMedia {
        let url: URL
        let expiresAt: Date
        var lastAccessAt: Date
    }
    private var signedMediaCache: [String: CachedSignedMedia] = [:]
    private let signedMediaCacheLimit = 128

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey,
        functionsBaseURL: URL = URL(string: "https://afwznqjpshybmqhlewmy.functions.supabase.co")!,
        signedMediaCacheTTL: TimeInterval = 540
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.functionsBaseURL = functionsBaseURL
        self.signedMediaCacheTTL = min(max(signedMediaCacheTTL, 0), 540)
    }

    func load(userId: String, accessToken: String, includeUnapproved: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_items"), resolvingAgainstBaseURL: false) else { return }
        var queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "sort_order.asc,created_at.desc")
        ]
        if !includeUnapproved {
            queryItems.append(URLQueryItem(name: "moderation_status", value: "eq.approved"))
        }
        components.queryItems = queryItems
        guard let reqURL = components.url else { return }
        var request = URLRequest(url: reqURL)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return }
        let decoded = (try? JSONDecoder().decode([PortfolioItem].self, from: data)) ?? []
        items = await resolveMediaURLs(in: decoded, accessToken: accessToken)
        await loadAuthors(userIDs: Set(items.map(\.userId)), accessToken: accessToken)
        if includeUnapproved {
            let retryable = items.filter {
                ["pending", "manual_review", "failed"].contains($0.moderationStatus)
            }
            Task { [weak self] in
                await self?.retryAutomaticModeration(
                    retryable,
                    accessToken: accessToken
                )
            }
        }
    }

    func loadSaved(userId: String, accessToken: String) async {
        isLoading = true
        defer { isLoading = false }

        guard var savesComponents = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/portfolio_item_saves"),
            resolvingAgainstBaseURL: false
        ) else { return }
        savesComponents.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "item_id"),
            URLQueryItem(name: "order", value: "created_at.desc")
        ]
        guard let savesURL = savesComponents.url else { return }
        var savesRequest = URLRequest(url: savesURL)
        savesRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        savesRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (savesData, savesResponse) = try? await session.data(for: savesRequest),
              let savesHTTP = savesResponse as? HTTPURLResponse,
              (200..<300).contains(savesHTTP.statusCode),
              let saves = try? JSONDecoder().decode([PortfolioSaveRow].self, from: savesData)
        else { return }

        let orderedIDs = saves.map(\.itemId)
        guard !orderedIDs.isEmpty else {
            items = []
            authors = [:]
            return
        }

        guard var itemsComponents = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/portfolio_items"),
            resolvingAgainstBaseURL: false
        ) else { return }
        itemsComponents.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(orderedIDs.joined(separator: ",")))"),
            URLQueryItem(name: "moderation_status", value: "eq.approved"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let itemsURL = itemsComponents.url else { return }
        var itemsRequest = URLRequest(url: itemsURL)
        itemsRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        itemsRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (itemsData, itemsResponse) = try? await session.data(for: itemsRequest),
              let itemsHTTP = itemsResponse as? HTTPURLResponse,
              (200..<300).contains(itemsHTTP.statusCode),
              let decoded = try? JSONDecoder().decode([PortfolioItem].self, from: itemsData)
        else { return }

        let byID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        let orderedItems = orderedIDs.compactMap { byID[$0] }
        items = await resolveMediaURLs(in: orderedItems, accessToken: accessToken)
        await loadAuthors(userIDs: Set(items.map(\.userId)), accessToken: accessToken)
    }

    func saveState(itemId: String, userId: String, accessToken: String) async -> PortfolioSaveState {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/portfolio_item_saves"),
            resolvingAgainstBaseURL: false
        ) else { return PortfolioSaveState(isSaved: false) }
        components.queryItems = [
            URLQueryItem(name: "item_id", value: "eq.\(itemId)"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "item_id")
        ]
        guard let url = components.url else { return PortfolioSaveState(isSaved: false) }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioSaveRow].self, from: data)
        else { return PortfolioSaveState(isSaved: false) }
        return PortfolioSaveState(isSaved: !rows.isEmpty)
    }

    func setSaved(itemId: String, saved: Bool, userId: String, accessToken: String) async -> Bool {
        if saved {
            var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/portfolio_item_saves"))
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try? JSONEncoder().encode([
                "item_id": AnyEncodable(itemId),
                "user_id": AnyEncodable(userId)
            ])
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return false }
            return (200..<300).contains(http.statusCode)
        }

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/portfolio_item_saves"),
            resolvingAgainstBaseURL: false
        ) else { return false }
        components.queryItems = [
            URLQueryItem(name: "item_id", value: "eq.\(itemId)"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)")
        ]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func loadAuthors(userIDs: Set<String>, accessToken: String) async {
        guard !userIDs.isEmpty,
              var components = URLComponents(
                url: baseURL.appendingPathComponent("rest/v1/profiles"),
                resolvingAgainstBaseURL: false
              )
        else { return }
        components.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(userIDs.joined(separator: ",")))"),
            URLQueryItem(name: "select", value: "id,name,avatar,nickname")
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioAuthor].self, from: data)
        else { return }
        authors = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    /// Uploads JPEG to Storage, then stores a stable public-shaped object ID.
    /// The private bucket can only be rendered through a signed URL.
    func addImage(jpegData: Data, userId: String, title: String?, description: String?, accessToken: String) async -> Bool {
        await addMedia(data: jpegData, type: "image", mime: "image/jpeg", ext: "jpg", userId: userId, title: title, description: description, accessToken: accessToken)
    }

    /// Uploads image/video and stores stable object IDs, never expiring URLs.
    func addMedia(data: Data, type: String, mime: String, ext: String, thumbnailData: Data? = nil, thumbnailHasCover: Bool = false, userId: String, title: String?, description: String?, accessToken: String) async -> Bool {
        let cleanType = type == "video" ? "video" : "image"
        let safeExt = ext.isEmpty ? (cleanType == "video" ? "mov" : "jpg") : ext
        let identifier = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        let path = "\(userId)/\(identifier).\(safeExt)"
        guard let canonicalURL = await uploadPortfolioMedia(
            data: data,
            path: path,
            mime: mime,
            accessToken: accessToken
        ) else {
            self.error = "Upload failed"
            return false
        }

        var thumbnailURL: String?
        if cleanType == "video", let thumbnailData {
            // Суффикс говорит экрану, что сверху превью — обложка (см. videoCoverSuffix).
            let thumbnailName = identifier + (thumbnailHasCover ? PortfolioMediaPolicy.videoCoverSuffix : ".jpg")
            thumbnailURL = await uploadPortfolioMedia(
                data: thumbnailData,
                path: "\(userId)/thumbnails/\(thumbnailName)",
                mime: "image/jpeg",
                accessToken: accessToken
            )
        }

        var insert = URLRequest(url: baseURL.appendingPathComponent("rest/v1/portfolio_items"))
        insert.httpMethod = "POST"
        insert.setValue(anonKey, forHTTPHeaderField: "apikey")
        insert.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        insert.setValue("application/json", forHTTPHeaderField: "Content-Type")
        insert.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let body: [String: AnyEncodable] = [
            "user_id": AnyEncodable(userId),
            "type": AnyEncodable(cleanType),
            "title": AnyEncodable(title ?? ""),
            "description": AnyEncodable(description ?? ""),
            "media_url": AnyEncodable(canonicalURL),
            "thumbnail_url": AnyEncodable(cleanType == "image" ? canonicalURL : (thumbnailURL ?? "")),
            "moderation_status": AnyEncodable("pending")
        ]
        insert.httpBody = try? JSONEncoder().encode(body)

        guard let (data, response) = try? await session.data(for: insert),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioItem].self, from: data),
              let inserted = rows.first
        else {
            self.error = "Insert failed"
            return false
        }
        let moderated = await moderate(
            itemId: inserted.id,
            moderationRevision: inserted.moderationRevision,
            accessToken: accessToken
        ) ?? inserted
        let resolved = await resolveMediaURLs(in: [moderated], accessToken: accessToken).first ?? moderated
        items.removeAll { $0.id == resolved.id }
        items.insert(resolved, at: 0)
        return true
    }

    private func uploadPortfolioMedia(
        data: Data,
        path: String,
        mime: String,
        accessToken: String
    ) async -> String? {
        let uploadURL = baseURL.appendingPathComponent("storage/v1/object/portfolio/\(path)")
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(anonKey, forHTTPHeaderField: "apikey")
        upload.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        upload.setValue(mime, forHTTPHeaderField: "Content-Type")
        upload.setValue("3600", forHTTPHeaderField: "Cache-Control")
        upload.setValue("false", forHTTPHeaderField: "x-upsert")
        upload.httpBody = data

        guard let (_, response) = try? await session.data(for: upload),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return nil
        }
        return baseURL
            .appendingPathComponent("storage/v1/object/public/portfolio/\(path)")
            .absoluteString
    }

    /// Exchanges the stable object identifier stored in Postgres for a
    /// short-lived private Storage URL. Validation is fail-closed: foreign
    /// hosts, ambiguous encoding and unexpected object layouts are rejected.
    func signedPortfolioMediaURL(
        canonicalURL: String,
        accessToken: String,
        forceRefresh: Bool = false
    ) async -> URL? {
        guard let host = baseURL.host,
              let objectPath = PortfolioMediaPolicy.objectPath(
                fromCanonicalURL: canonicalURL,
                expectedHost: host
              )
        else { return nil }

        let now = Date()
        if forceRefresh {
            signedMediaCache.removeValue(forKey: objectPath)
        } else if var cached = signedMediaCache[objectPath], cached.expiresAt > now {
            cached.lastAccessAt = now
            signedMediaCache[objectPath] = cached
            return cached.url
        } else {
            signedMediaCache.removeValue(forKey: objectPath)
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/storage/v1/object/sign/portfolio/\(objectPath)"
        components.query = nil
        components.fragment = nil
        guard let signURL = components.url else { return nil }

        var request = URLRequest(url: signURL)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["expiresIn": signedMediaLifetimeSeconds]
        )

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSignedURL = (payload["signedURL"] as? String) ?? (payload["signedUrl"] as? String),
              let signedURL = validatedSignedURL(rawSignedURL, objectPath: objectPath)
        else { return nil }

        signedMediaCache[objectPath] = CachedSignedMedia(
            url: signedURL,
            expiresAt: now.addingTimeInterval(signedMediaCacheTTL),
            lastAccessAt: now
        )
        pruneSignedMediaCache()
        return signedURL
    }

    private func resolveMediaURLs(
        in sourceItems: [PortfolioItem],
        accessToken: String
    ) async -> [PortfolioItem] {
        var resolvedItems: [PortfolioItem] = []
        resolvedItems.reserveCapacity(sourceItems.count)
        for var item in sourceItems {
            if let canonical = item.mediaUrl, !canonical.isEmpty {
                item.signedMediaUrl = await signedPortfolioMediaURL(
                    canonicalURL: canonical,
                    accessToken: accessToken
                )?.absoluteString
            }
            if let canonical = item.thumbnailUrl, !canonical.isEmpty {
                item.signedThumbnailUrl = await signedPortfolioMediaURL(
                    canonicalURL: canonical,
                    accessToken: accessToken
                )?.absoluteString
            }
            resolvedItems.append(item)
        }
        return resolvedItems
    }

    private func validatedSignedURL(_ rawValue: String, objectPath: String) -> URL? {
        let absoluteValue: String
        if rawValue.hasPrefix("https://") {
            absoluteValue = rawValue
        } else if rawValue.hasPrefix("/storage/v1/") {
            absoluteValue = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + rawValue
        } else if rawValue.hasPrefix("/object/sign/") {
            absoluteValue = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/storage/v1" + rawValue
        } else {
            return nil
        }

        guard let components = URLComponents(string: absoluteValue),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == baseURL.host?.lowercased(),
              components.port == baseURL.port,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/storage/v1/object/sign/portfolio/\(objectPath)",
              components.queryItems?.contains(where: {
                $0.name == "token" && $0.value?.isEmpty == false
              }) == true
        else { return nil }
        return components.url
    }

    private func pruneSignedMediaCache() {
        let now = Date()
        signedMediaCache = signedMediaCache.filter { $0.value.expiresAt > now }
        guard signedMediaCache.count > signedMediaCacheLimit else { return }
        let overflow = signedMediaCache.count - signedMediaCacheLimit
        let oldestKeys = signedMediaCache
            .sorted { $0.value.lastAccessAt < $1.value.lastAccessAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys { signedMediaCache.removeValue(forKey: key) }
    }

    @discardableResult
    func moderate(
        itemId: String,
        moderationRevision: Int64?,
        accessToken: String,
        action: String = "moderate"
    ) async -> PortfolioItem? {
        var request = URLRequest(url: functionsBaseURL.appendingPathComponent("moderate-portfolio"))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            PortfolioModerationRequest(
                itemId: itemId,
                moderationRevision: moderationRevision,
                action: action
            )
        )

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let result = try? JSONDecoder().decode(PortfolioModerationResponse.self, from: data)
        else {
            if let index = items.firstIndex(where: { $0.id == itemId }) {
                items[index].moderationStatusRaw = "pending"
                items[index].moderationReason = "Автоматическая проверка будет повторена"
                return items[index]
            }
            return nil
        }

        if let item = result.item {
            let resolved = await resolveMediaURLs(in: [item], accessToken: accessToken).first ?? item
            if let index = items.firstIndex(where: { $0.id == resolved.id }) {
                items[index] = resolved
            }
            return resolved
        }
        return nil
    }

    private func retryAutomaticModeration(
        _ retryableItems: [PortfolioItem],
        accessToken: String
    ) async {
        for item in retryableItems {
            _ = await moderate(
                itemId: item.id,
                moderationRevision: item.moderationRevision,
                accessToken: accessToken,
                action: "retry"
            )
        }
    }

    func loadComments(itemId: String, accessToken: String) async -> [PortfolioComment] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_comments"), resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "portfolio_id", value: "eq.\(itemId)"),
            URLQueryItem(name: "select", value: "id,portfolio_id,user_id,text,created_at"),
            URLQueryItem(name: "order", value: "created_at.asc")
        ]
        guard let reqURL = components.url else { return [] }
        var request = URLRequest(url: reqURL)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return [] }
        let rows = (try? JSONDecoder().decode([PortfolioComment].self, from: data)) ?? []
        return await attachCommentAuthors(rows, accessToken: accessToken)
    }

    /// Имя и аватар автора комментария — из `profiles` (ник или имя, не email).
    private func attachCommentAuthors(_ comments: [PortfolioComment], accessToken: String) async -> [PortfolioComment] {
        let userIDs = Set(comments.map(\.userId))
        guard !userIDs.isEmpty,
              var components = URLComponents(
                url: baseURL.appendingPathComponent("rest/v1/profiles"),
                resolvingAgainstBaseURL: false
              )
        else { return comments }
        components.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(userIDs.joined(separator: ",")))"),
            URLQueryItem(name: "select", value: "id,name,avatar,nickname")
        ]
        guard let url = components.url else { return comments }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioAuthor].self, from: data)
        else { return comments }
        let byID = Dictionary(rows.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return comments.map { comment in
            var named = comment
            if let author = byID[comment.userId.lowercased()] {
                named.userName = Self.publicName(of: author)
                named.userAvatar = author.avatar
            }
            return named
        }
    }

    private static func publicName(of author: PortfolioAuthor) -> String? {
        if let nickname = author.nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            return nickname
        }
        if let name = author.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return nil
    }

    /// `userName`/`userAvatar` только для показа своего нового комментария сразу —
    /// на сервер они не уходят (в `portfolio_comments` таких колонок нет).
    func addComment(itemId: String, userId: String, userName: String?, userAvatar: String?, text: String, accessToken: String) async -> PortfolioComment? {
        var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/portfolio_comments"))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let body: [String: AnyEncodable] = [
            "portfolio_id": AnyEncodable(itemId),
            "user_id": AnyEncodable(userId),
            // Сайт режет комментарий до 1000 символов — держим так же.
            "text": AnyEncodable(String(text.prefix(1000)))
        ]
        request.httpBody = try? JSONEncoder().encode(body)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioComment].self, from: data),
              var created = rows.first
        else { return nil }
        created.userName = userName
        created.userAvatar = userAvatar
        if userName == nil {
            // Имя автора берём из профиля, как у остальных комментариев.
            return (await attachCommentAuthors([created], accessToken: accessToken)).first ?? created
        }
        return created
    }

    func delete(itemId: String, accessToken: String) async {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_items"), resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(itemId)")]
        guard let reqURL = components.url else { return }
        var request = URLRequest(url: reqURL)
        request.httpMethod = "DELETE"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            items.removeAll { $0.id == itemId }
        }
    }

    /// Текущее превью кейса (для смены обложки видео: из него берём сетку кадров).
    func thumbnailData(for item: PortfolioItem, accessToken: String) async -> Data? {
        guard let canonical = item.thumbnailUrl, !canonical.isEmpty,
              let url = await signedPortfolioMediaURL(
                canonicalURL: canonical,
                accessToken: accessToken,
                forceRefresh: true
              ),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }

    /// `newVideoThumbnail` — новое превью «обложка + кадры» (смена обложки видео).
    /// Загружается новым файлом (бакет неизменяемый), затем thumbnail_url меняется
    /// вместе с текстом; сервер сам переводит кейс на повторную автопроверку.
    func updateDetails(
        itemId: String,
        title: String?,
        description: String?,
        newVideoThumbnail: Data? = nil,
        ownerId: String? = nil,
        accessToken: String
    ) async -> PortfolioItem? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_items"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(itemId)")]
        guard let reqURL = components.url else { return nil }

        var newThumbnailURL: String?
        if let newVideoThumbnail, let ownerId {
            let identifier = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
            guard let uploaded = await uploadPortfolioMedia(
                data: newVideoThumbnail,
                path: "\(ownerId)/thumbnails/\(identifier)\(PortfolioMediaPolicy.videoCoverSuffix)",
                mime: "image/jpeg",
                accessToken: accessToken
            ) else {
                self.error = "Upload failed"
                return nil
            }
            newThumbnailURL = uploaded
        }

        var request = URLRequest(url: reqURL)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        var body: [String: AnyEncodable] = [
            "title": AnyEncodable(title ?? ""),
            "description": AnyEncodable(description ?? "")
        ]
        if let newThumbnailURL {
            body["thumbnail_url"] = AnyEncodable(newThumbnailURL)
        }
        request.httpBody = try? JSONEncoder().encode(body)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioItem].self, from: data),
              let updated = rows.first
        else { return nil }

        if let index = items.firstIndex(where: { $0.id == itemId }) {
            let moderated: PortfolioItem
            if let result = await moderate(
                itemId: updated.id,
                moderationRevision: updated.moderationRevision,
                accessToken: accessToken
            ) {
                moderated = result
            } else {
                moderated = await resolveMediaURLs(in: [updated], accessToken: accessToken).first ?? updated
            }
            items[index] = moderated
            return moderated
        }
        if let moderated = await moderate(
            itemId: updated.id,
            moderationRevision: updated.moderationRevision,
            accessToken: accessToken
        ) {
            return moderated
        }
        return await resolveMediaURLs(in: [updated], accessToken: accessToken).first ?? updated
    }

    // Лайки — `public.portfolio_likes` (portfolio_id text, user_id, UNIQUE пара),
    // таблица, которая реально есть в проде. Раньше iOS ходил в несуществующую
    // `portfolio_item_likes` → сердечко никогда не сохранялось (Адильхан 09.10).
    // идея: сайт сейчас тоже пишет в portfolio_item_* — перевести его сюда же.
    func likeState(itemId: String, currentUserId: String, accessToken: String) async -> PortfolioLikeState {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_likes"), resolvingAgainstBaseURL: false) else {
            return PortfolioLikeState(isLiked: false, count: 0)
        }
        components.queryItems = [
            URLQueryItem(name: "portfolio_id", value: "eq.\(itemId)"),
            URLQueryItem(name: "select", value: "user_id")
        ]
        guard let reqURL = components.url else {
            return PortfolioLikeState(isLiked: false, count: 0)
        }
        var request = URLRequest(url: reqURL)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([PortfolioLikeRow].self, from: data)
        else {
            return PortfolioLikeState(isLiked: false, count: 0)
        }
        return PortfolioLikeState(
            isLiked: rows.contains { $0.userId.lowercased() == currentUserId.lowercased() },
            count: rows.count
        )
    }

    func setLiked(itemId: String, liked: Bool, currentUserId: String, accessToken: String) async -> Bool {
        if liked {
            // on_conflict по UNIQUE (portfolio_id, user_id): повторный лайк не падает.
            guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_likes"), resolvingAgainstBaseURL: false) else {
                return false
            }
            components.queryItems = [URLQueryItem(name: "on_conflict", value: "portfolio_id,user_id")]
            guard let reqURL = components.url else { return false }
            var request = URLRequest(url: reqURL)
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("resolution=ignore-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
            let body: [String: AnyEncodable] = [
                "portfolio_id": AnyEncodable(itemId),
                "user_id": AnyEncodable(currentUserId)
            ]
            request.httpBody = try? JSONEncoder().encode(body)
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return false }
            // 409 — лайк уже стоит (например, поставлен с сайта): это успех.
            return (200..<300).contains(http.statusCode) || http.statusCode == 409
        } else {
            guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/portfolio_likes"), resolvingAgainstBaseURL: false) else {
                return false
            }
            components.queryItems = [
                URLQueryItem(name: "portfolio_id", value: "eq.\(itemId)"),
                URLQueryItem(name: "user_id", value: "eq.\(currentUserId)")
            ]
            guard let reqURL = components.url else { return false }
            var request = URLRequest(url: reqURL)
            request.httpMethod = "DELETE"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return false }
            return (200..<300).contains(http.statusCode)
        }
    }
}

private struct PortfolioLikeRow: Codable {
    let userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

private struct PortfolioSaveRow: Codable {
    let itemId: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
    }
}

private struct PortfolioModerationRequest: Encodable {
    let itemId: String
    let moderationRevision: Int64?
    let action: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case moderationRevision = "moderation_revision"
        case action
    }
}

private struct PortfolioModerationResponse: Codable {
    let status: String?
    let reason: String?
    let item: PortfolioItem?
}
