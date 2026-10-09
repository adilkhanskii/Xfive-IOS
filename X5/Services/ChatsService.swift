import Foundation

// MARK: - Models

struct ChatRoom: Codable, Identifiable, Hashable {
    let id: String
    let participants: [String]
    let taskId: String?
    let taskTitle: String?
    let lastMessage: String?
    let lastMessageAt: String?
    let unread: [String: Int]?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, participants, unread
        case taskId = "task_id"
        case taskTitle = "task_title"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case createdAt = "created_at"
    }

    func otherParticipantId(currentUser: String) -> String? {
        let me = currentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != me }
    }

    func isValidPeerChat(currentUser: String) -> Bool {
        let me = currentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanParticipants = participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !me.isEmpty,
              cleanParticipants.contains(me),
              Set(cleanParticipants).count >= 2,
              otherParticipantId(currentUser: me) != nil
        else { return false }
        return true
    }

    func unreadCount(for userId: String) -> Int {
        unread?[userId] ?? 0
    }

    /// Immutable copy with backfilled last_message — used when refreshing the chats list.
    func with(lastMessage: String?, lastMessageAt: String?) -> ChatRoom {
        ChatRoom(
            id: id,
            participants: participants,
            taskId: taskId,
            taskTitle: taskTitle,
            lastMessage: lastMessage ?? self.lastMessage,
            lastMessageAt: lastMessageAt ?? self.lastMessageAt,
            unread: unread,
            createdAt: createdAt
        )
    }

    func with(unread: [String: Int]?) -> ChatRoom {
        ChatRoom(
            id: id,
            participants: participants,
            taskId: taskId,
            taskTitle: taskTitle,
            lastMessage: lastMessage,
            lastMessageAt: lastMessageAt,
            unread: unread,
            createdAt: createdAt
        )
    }
}

struct ChatMessageRow: Codable, Identifiable, Hashable {
    let id: String
    let chatId: String
    let senderId: String
    let type: String           // text | image | video | audio | task_card
    let content: String?
    let mediaUrl: String?
    let mediaMime: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, content
        case chatId = "chat_id"
        case senderId = "sender_id"
        case mediaUrl = "media_url"
        case mediaMime = "media_mime"
        case createdAt = "created_at"
    }
}

/// Закреп чата с сервера (chats.pinned_message_id). Отдельно от ChatRoom,
/// чтобы не трогать кэш списка чатов и все `with(...)`.
struct ChatPinState: Codable, Hashable {
    let messageId: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "pinned_message_id"
    }
}

struct ChatTaskCardPayload: Codable, Hashable {
    let id: String
    let title: String
    let description: String?
    let budget: String?
    let category: String?
    let authorName: String?

    init(task: HubTask) {
        self.id = task.id
        self.title = task.title
        self.description = task.description
        self.budget = task.budget
        self.category = task.category
        self.authorName = task.authorName
    }

    static func decode(_ content: String?) -> ChatTaskCardPayload? {
        guard let content,
              let data = content.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ChatTaskCardPayload.self, from: data)
    }

    func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return title }
        return string
    }

    var preview: String {
        "Задание: \(title)"
    }

    var copyText: String {
        [title, description, budget].compactMap { value in
            let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean?.isEmpty == false ? clean : nil
        }.joined(separator: "\n")
    }
}

extension ChatMessageRow {
    var taskCard: ChatTaskCardPayload? {
        guard type == "task_card" else { return nil }
        return ChatTaskCardPayload.decode(content)
    }
}

struct ChatMessagePage: Equatable {
    let rows: [ChatMessageRow]
    let hasMore: Bool
}

enum ChatMessageTimeline {
    static func merge(_ current: [ChatMessageRow], with incoming: [ChatMessageRow]) -> [ChatMessageRow] {
        var byID: [String: ChatMessageRow] = [:]
        for row in current { byID[row.id] = row }
        for row in incoming { byID[row.id] = row }
        return byID.values.sorted { lhs, rhs in
            let left = date(lhs.createdAt)
            let right = date(rhs.createdAt)
            if left == right { return lhs.id < rhs.id }
            return left < right
        }
    }

    private static func date(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
            ?? .distantPast
    }
}

enum ChatMediaPolicy {
    static let maximumImageBytes = 12 * 1_024 * 1_024
    static let maximumAudioBytes = 20 * 1_024 * 1_024
    /// The current Supabase project is on the 50 MB Storage tier. Keep the
    /// same safety boundary as CourseUP so protocol overhead never turns an
    /// otherwise valid video into a late 413 response.
    static let maximumVideoBytes = 47_000_000
    static let bucket = "chat-media"
    static let canonicalPublicPathPrefix = "/storage/v1/object/public/\(bucket)/"
    static let canonicalAuthenticatedPathPrefix = "/storage/v1/object/authenticated/\(bucket)/"

    static func accepts(byteCount: Int, mime: String) -> Bool {
        guard byteCount > 0 else { return false }
        switch mime.lowercased() {
        case "image/jpeg", "image/png", "image/heic":
            return byteCount <= maximumImageBytes
        case "audio/m4a", "audio/mp4", "audio/aac", "audio/mpeg":
            return byteCount <= maximumAudioBytes
        case "video/mp4", "video/quicktime", "video/x-m4v":
            return byteCount <= maximumVideoBytes
        default:
            return false
        }
    }

    static func safePathComponent(_ value: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty,
              value.count <= 200,
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return value
    }

    /// Extracts the private Storage object name from the public-shaped URL kept
    /// in `messages.media_url`. Only the app's Supabase host and the exact
    /// `chat-media` bucket are accepted; ambiguous encoded paths are rejected.
    static func objectPath(
        fromCanonicalURL rawValue: String,
        expectedHost: String = "afwznqjpshybmqhlewmy.supabase.co",
        expectedChatID: String? = nil
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
        } else if encodedPath.hasPrefix(canonicalAuthenticatedPathPrefix) {
            // Accepted for rows written during the short authenticated-URL
            // transition; the database normalises new rows to the public form.
            prefix = canonicalAuthenticatedPathPrefix
        } else {
            return nil
        }

        let encodedObjectPath = String(encodedPath.dropFirst(prefix.count))
        guard let decodedObjectPath = encodedObjectPath.removingPercentEncoding,
              decodedObjectPath == encodedObjectPath,
              isValidObjectPath(decodedObjectPath)
        else { return nil }

        if let expectedChatID {
            guard let safeChatID = safePathComponent(expectedChatID) else { return nil }
            let pathComponents = decodedObjectPath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            let isCanonicalLayout = pathComponents.first == safeChatID
            // Android legacy rows used `chats/<chat_id>/...`. Keep this as a
            // read-only compatibility path; all new iOS uploads use
            // `<chat_id>/<user_id>/<file>`.
            let isLegacyAndroidLayout = pathComponents.count >= 3
                && pathComponents[0] == "chats"
                && pathComponents[1] == safeChatID
            guard isCanonicalLayout || isLegacyAndroidLayout else { return nil }
        }
        return decodedObjectPath
    }

    static func uploadObjectPath(
        chatID: String,
        userID: String,
        fileExtension: String,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        nonce: String = UUID().uuidString
    ) -> String? {
        guard timestamp > 0,
              let safeChatID = safePathComponent(chatID),
              let safeUserID = safePathComponent(userID),
              let safeExtension = safePathComponent(fileExtension.lowercased()),
              let safeNonce = safePathComponent(nonce)
        else { return nil }
        let path = "\(safeChatID)/\(safeUserID)/\(timestamp)-\(safeNonce.prefix(12)).\(safeExtension)"
        return isValidObjectPath(path) ? path : nil
    }

    static func canonicalURL(objectPath: String, baseURL: URL) -> URL? {
        guard isValidObjectPath(objectPath),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil
        else { return nil }
        components.path = canonicalPublicPathPrefix + objectPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isValidObjectPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 1_024,
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("//"),
              !value.contains(".."),
              !value.contains("\\")
        else { return false }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.count <= 255
                && component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

// MARK: - Service

@MainActor
final class ChatsService: ObservableObject {
    @Published private(set) var chats: [ChatRoom] = []
    @Published private(set) var isLoading: Bool = false
    @Published var error: String?

    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let signedMediaCacheTTL: TimeInterval
    private let signedMediaLifetimeSeconds = 600
    private var unauthorizedAccessTokenProvider: ((String) async -> String?)?

    private struct CachedSignedMedia {
        let url: URL
        let expiresAt: Date
        var lastAccessAt: Date
    }
    private static var signedMediaCache: [String: CachedSignedMedia] = [:]
    private static let signedMediaCacheLimit = 128

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://afwznqjpshybmqhlewmy.supabase.co")!,
        anonKey: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmd3pucWpwc2h5Ym1xaGxld215Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzNTUxMTcsImV4cCI6MjA4NTkzMTExN30.p51iPiMEUSETS9Ot_qkmtA3IcqA23kadgoBLLQDXuL0",
        signedMediaCacheTTL: TimeInterval = 540
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.signedMediaCacheTTL = min(max(signedMediaCacheTTL, 0), 540)
    }

    func configureAccessTokenProvider(auth: Auth) {
        let expectedUserId = auth.userId
        unauthorizedAccessTokenProvider = { [weak auth] rejectedToken in
            guard let auth, let expectedUserId else { return nil }
            return await auth.accessTokenAfterUnauthorized(
                rejectedAccessToken: rejectedToken,
                expectedUserId: expectedUserId
            )
        }
    }

    func configureAccessTokenProvider(
        _ provider: @escaping (String) async -> String?
    ) {
        unauthorizedAccessTokenProvider = provider
    }

    // MARK: - Peer profile cache
    //
    // Avoids the "avatar reloads on every chat re-entry" UX issue. Without
    // this, ChatThreadView.task fires loadPublicProfile each time the view
    // appears; a freshly-decoded UserProfile carries a re-signed avatar URL
    // whose query string differs slightly between calls, busting the
    // CachedAsyncImage URL key even though ImageCache has the bytes on disk.
    //
    // TTL is short (10 min) so muted/blocked/Pro state changes still
    // propagate within a session without forcing a full sign-out.
    private struct CachedPeer { let profile: UserProfile; let at: Date }
    private static var peerCache: [String: CachedPeer] = [:]
    private let peerCacheTTL: TimeInterval = 600

    /// Synchronous read for views that need a peer's profile at frame 1
    /// (e.g. ChatThreadView header on cold-launch nav). Returns nil if the
    /// row isn't cached or has expired — caller should kick off an async
    /// loadPublicProfile in that case.
    func cachedPeer(_ userId: String) -> UserProfile? {
        guard let entry = Self.peerCache[userId] else { return nil }
        if Date().timeIntervalSince(entry.at) > peerCacheTTL {
            Self.peerCache.removeValue(forKey: userId)
            return nil
        }
        return entry.profile
    }

    /// Drop the cached peer (used after sign-out or when stale data is
    /// known to be wrong, e.g. after the user blocks someone).
    func invalidatePeer(_ userId: String) {
        Self.peerCache.removeValue(forKey: userId)
    }

    // MARK: - Message cache
    //
    // Open-chat lag was "blank screen → spinner → bubbles" because every
    // ChatThreadView entry hit the network from cold. Cache last fetched
    // messages in memory + on disk so the UI can paint instantly while we
    // refetch in the background.
    private static var messageMemoryCache: [String: [ChatMessageRow]] = [:]
    private static var messageLastRefreshAt: [String: Date] = [:]
    private let messageRefreshTTL: TimeInterval = 30
    static let messagePageSize = 60

    nonisolated private static func cacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("x5-chats", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Belt-and-braces: iOS already excludes Caches/ from iCloud backup
            // on most devices, but explicitly mark the directory so signed
            // media URLs and message text never leak into a third-party
            // backup if Apple changes that default.
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return dir
    }

    private func messageCacheURL(chatId: String) -> URL {
        Self.cacheRoot().appendingPathComponent("\(chatId).json")
    }

    /// Cap on cached chats — older files (by mtime) get pruned past this.
    /// Keeps Caches/x5-chats/ bounded for chat-heavy users.
    private static let cacheChatLimit = 50

    /// Wipes everything in `Caches/x5-chats/`. Called from Auth.signOut so
    /// a different user signing in on the same device can't read the
    /// previous user's message history off disk.
    nonisolated static func clearDiskCache() {
        let dir = cacheRoot()
        try? FileManager.default.removeItem(at: dir)
    }

    static func clearMemoryCache() {
        peerCache.removeAll()
        messageMemoryCache.removeAll()
        messageLastRefreshAt.removeAll()
        signedMediaCache.removeAll()
    }

    /// Synchronous read of cached messages — returns memory layer first,
    /// falls back to disk JSON. Used by views to paint instantly on open.
    func cachedMessages(chatId: String) -> [ChatMessageRow] {
        if let mem = Self.messageMemoryCache[chatId] { return mem }
        let url = messageCacheURL(chatId: chatId)
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([ChatMessageRow].self, from: data)
        else { return [] }
        Self.messageMemoryCache[chatId] = rows
        return rows
    }

    func persistMessageCache(chatId: String, rows: [ChatMessageRow]) {
        // Optimistic rows are view-local and have retry metadata outside the
        // wire model. Never persist them as if the server accepted them.
        let rows = rows.filter { !$0.id.hasPrefix("local-") }
        Self.messageMemoryCache[chatId] = rows
        let url = messageCacheURL(chatId: chatId)
        // Detach so disk write doesn't block the actor. Prune-after-write
        // keeps the directory bounded — captures only the cap so it doesn't
        // need to call back into the @MainActor instance.
        let cap = Self.cacheChatLimit
        Task.detached(priority: .utility) { [rows, url, cap] in
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? data.write(to: url, options: .atomic)
            Self.pruneDirectoryStatic(cap: cap)
        }
    }

    private func shouldRefreshMessages(chatId: String, forceRefresh: Bool) -> Bool {
        if forceRefresh { return true }
        guard let last = Self.messageLastRefreshAt[chatId] else { return true }
        return Date().timeIntervalSince(last) > messageRefreshTTL
    }

    /// Static prune so the disk-write detached task doesn't need to hop back
    /// to the main actor.
    nonisolated private static func pruneDirectoryStatic(cap: Int) {
        let dir = cacheRoot()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        guard files.count > cap else { return }
        let sorted = files.sorted { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad > bd
        }
        for stale in sorted.dropFirst(cap) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    static func chatId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    /// Sends `request` with the given Bearer token. If Supabase returns 401, refresh
    /// the session via the global SupabaseClient and retry once with the new token.
    /// Surfaces a human error to `self.error` on any non-2xx response.
    private func sendAuthed(_ request: URLRequest, accessToken: String) async -> (Data, HTTPURLResponse)? {
        do {
            let (data, resp) = try await session.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                // Refresh only through the shared Auth/SupabaseClient
                // single-flight session. Never rotate a Keychain token behind
                // Auth's in-memory session.
                if let unauthorizedAccessTokenProvider,
                   let newToken = await unauthorizedAccessTokenProvider(accessToken),
                   !newToken.isEmpty,
                   newToken != accessToken {
                    var retry = request
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    let (rdata, rresp) = try await session.data(for: retry)
                    guard let rhttp = rresp as? HTTPURLResponse else { return nil }
                    if !(200..<300).contains(rhttp.statusCode) {
                        let body = String(data: rdata, encoding: .utf8) ?? ""
                        self.error = "Сервер: \(rhttp.statusCode). \(body)"
                        return (rdata, rhttp)
                    }
                    return (rdata, rhttp)
                }
                self.error = "Сессия истекла. Выйди и войди снова."
                return nil
            }
            guard let http = resp as? HTTPURLResponse else { return nil }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                self.error = "Сервер: \(http.statusCode). \(body)"
            }
            return (data, http)
        } catch {
            self.error = "Сеть: \(error.localizedDescription)"
            return nil
        }
    }

    /// Load minimal public profile for any user by ID (used in chat header / row).
    /// Result is memoised in `peerCache` for `peerCacheTTL` so re-entering the
    /// same chat doesn't refetch — and, more importantly, doesn't hand a new
    /// signed avatar URL to CachedAsyncImage which would bust its cache key.
    func loadPublicProfile(userId: String, accessToken: String) async -> UserProfile? {
        if let cached = cachedPeer(userId) { return cached }
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userId)"),
            URLQueryItem(
                name: "select",
                value: "id,name,nickname,avatar,bio,services,plan,social_links,user_role,specialist_category,show_in_hub,is_public,signup_number,language,last_seen,is_verified,verified_until"
            )
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([UserProfile].self, from: data)
        else { return nil }
        if let row = rows.first {
            Self.peerCache[userId] = CachedPeer(profile: row, at: Date())
            return row
        }
        return nil
    }

    func loadChats(currentUserId: String, accessToken: String) async {
        isLoading = true
        defer { isLoading = false }
        error = nil
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "participants", value: "cs.{\(currentUserId)}"),
            URLQueryItem(name: "order", value: "last_message_at.desc.nullslast")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode) else { return }
        var rows = (try? JSONDecoder().decode([ChatRoom].self, from: data)) ?? []

        // Backfill last_message for rows where it's null (writes from old buggy builds
        // that posted messages without bumping the chat row).
        for (index, chat) in rows.enumerated() {
            guard chat.lastMessage == nil || chat.lastMessage?.isEmpty == true else { continue }
            if let recent = await fetchMostRecentMessagePreview(chatId: chat.id, accessToken: accessToken) {
                rows[index] = chat.with(lastMessage: recent.text, lastMessageAt: recent.at)
            }
        }
        chats = rows
    }

    /// Returns a 1-line preview + timestamp for the latest message of a chat, or nil.
    private func fetchMostRecentMessagePreview(chatId: String, accessToken: String) async -> (text: String, at: String)? {
        var c = URLComponents(url: baseURL.appendingPathComponent("rest/v1/messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "chat_id", value: "eq.\(chatId)"),
            URLQueryItem(name: "select", value: "type,content,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "1")
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(req, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = arr.first
        else { return nil }
        let type = row["type"] as? String ?? "text"
        let at = row["created_at"] as? String ?? ""
        let preview: String
        switch type {
        case "image": preview = "📷 Фото"
        case "audio": preview = "🎤 Голосовое"
        case "file":  preview = "📎 Файл"
        case "task_card":
            preview = ChatTaskCardPayload.decode(row["content"] as? String)?.preview ?? "Задание"
        default:      preview = (row["content"] as? String) ?? ""
        }
        return (preview, at)
    }

    func loadMessages(chatId: String, accessToken: String, forceRefresh: Bool = false) async -> [ChatMessageRow] {
        let cached = cachedMessages(chatId: chatId)
        if !cached.isEmpty && !shouldRefreshMessages(chatId: chatId, forceRefresh: forceRefresh) {
            return cached
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "chat_id", value: "eq.\(chatId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(Self.messagePageSize))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode) else {
            // Network failed — return whatever's cached so the UI still has bubbles.
            return cachedMessages(chatId: chatId)
        }
        let rows = ((try? JSONDecoder().decode([ChatMessageRow].self, from: data)) ?? []).reversed()
        let orderedRows = Array(rows)
        Self.messageLastRefreshAt[chatId] = Date()
        persistMessageCache(chatId: chatId, rows: orderedRows)
        return orderedRows
    }

    func loadOlderMessages(
        chatId: String,
        before createdAt: String,
        accessToken: String
    ) async -> ChatMessagePage {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "chat_id", value: "eq.\(chatId)"),
            URLQueryItem(name: "created_at", value: "lt.\(createdAt)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(Self.messagePageSize))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode) else {
            return ChatMessagePage(rows: [], hasMore: false)
        }
        let descending = (try? JSONDecoder().decode([ChatMessageRow].self, from: data)) ?? []
        return ChatMessagePage(
            rows: Array(descending.reversed()),
            hasMore: descending.count == Self.messagePageSize
        )
    }

    func loadNewerMessages(
        chatId: String,
        after createdAt: String,
        accessToken: String
    ) async -> [ChatMessageRow] {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "chat_id", value: "eq.\(chatId)"),
            URLQueryItem(name: "created_at", value: "gt.\(createdAt)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.asc"),
            URLQueryItem(name: "limit", value: "100")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode) else { return [] }
        return (try? JSONDecoder().decode([ChatMessageRow].self, from: data)) ?? []
    }

    func loadChat(chatId: String, accessToken: String) async -> ChatRoom? {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(chatId)"),
            URLQueryItem(name: "select", value: "*")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatRoom].self, from: data)
        else { return nil }
        return rows.first
    }

    // MARK: - Закреп сообщения (как в Telegram)
    // Один закреп на чат, общий для обоих участников: поле chats.pinned_message_id
    // (миграция 20261009190000). Раньше закреп жил только в UserDefaults одного телефона —
    // плашки не было, собеседник и сайт его не видели (баг Адильхана 09.10).

    /// nil — не удалось узнать (сеть, старая база без поля): экран оставляет то, что уже показывал.
    /// `.init(messageId: nil)` — закрепа нет.
    func loadPinnedMessage(chatId: String, accessToken: String) async -> ChatPinState? {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(chatId)"),
            URLQueryItem(name: "select", value: "pinned_message_id")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Не через sendAuthed: до миграции сервер ответит 400, а это не ошибка для пользователя.
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatPinState].self, from: data),
              let row = rows.first
        else { return nil }
        return row
    }

    /// messageId == nil — открепить. Возвращает false, если сервер отказал.
    func setPinnedMessage(chatId: String, messageId: String?, accessToken: String) async -> Bool {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(chatId)")]
        var patch = URLRequest(url: components.url!)
        patch.httpMethod = "PATCH"
        patch.setValue(anonKey, forHTTPHeaderField: "apikey")
        patch.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // representation — чтобы отличить «обновили» от «RLS молча не дал (0 строк)».
        patch.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let value: Any = messageId.map { $0 as Any } ?? NSNull()
        patch.httpBody = try? JSONSerialization.data(withJSONObject: ["pinned_message_id": value])
        guard let (data, http) = await sendAuthed(patch, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatPinState].self, from: data),
              let row = rows.first,
              row.messageId == messageId
        else {
            // Свою ошибку экран показывает сам; общий error не держим, иначе он всплывёт
            // позже в чужом алерте (например, «не отправилось фото»).
            error = nil
            return false
        }
        error = nil
        return true
    }

    /// Одно сообщение по id — для превью в плашке, если закреп старше загруженной страницы.
    /// Фильтр chat_id — чтобы в плашку не попало сообщение из чужого чата.
    func loadMessage(id: String, chatId: String, accessToken: String) async -> ChatMessageRow? {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "chat_id", value: "eq.\(chatId)"),
            URLQueryItem(name: "select", value: "*")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatMessageRow].self, from: data)
        else { return nil }
        return rows.first
    }

    func markRead(chatId: String, currentUserId: String, accessToken: String) async -> ChatRoom? {
        error = nil
        var rpc = URLRequest(url: baseURL.appendingPathComponent("rest/v1/rpc/x5_mark_chat_read"))
        rpc.httpMethod = "POST"
        rpc.setValue(anonKey, forHTTPHeaderField: "apikey")
        rpc.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        rpc.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rpc.httpBody = try? JSONSerialization.data(withJSONObject: ["p_chat_id": chatId])
        if let (data, http) = await sendAuthed(rpc, accessToken: accessToken),
           (200..<300).contains(http.statusCode),
           let room = decodeChatRoom(from: data) {
            error = nil
            return room
        }

        // Fallback for older databases before the RPC migration is applied.
        guard let room = await loadChat(chatId: chatId, accessToken: accessToken) else { return nil }
        var nextUnread = room.unread ?? [:]
        nextUnread[currentUserId] = 0

        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(chatId)")]
        var patch = URLRequest(url: components.url!)
        patch.httpMethod = "PATCH"
        patch.setValue(anonKey, forHTTPHeaderField: "apikey")
        patch.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        patch.setValue("return=representation", forHTTPHeaderField: "Prefer")
        patch.httpBody = try? JSONEncoder().encode(["unread": AnyEncodable(nextUnread)])
        guard let (data, http) = await sendAuthed(patch, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatRoom].self, from: data),
              let updated = rows.first
        else { return room.with(unread: nextUnread) }
        error = nil
        return updated
    }

    private func decodeChatRoom(from data: Data) -> ChatRoom? {
        if let room = try? JSONDecoder().decode(ChatRoom.self, from: data) {
            return room
        }
        if let rows = try? JSONDecoder().decode([ChatRoom].self, from: data) {
            return rows.first
        }
        return nil
    }

    /// Ensures a chat row exists for the (me, other) pair, optionally tagged with a task.
    /// Returns nil and sets `self.error` on failure (RLS, network, expired token).
    func ensureChat(otherUserId: String, currentUserId: String, taskId: String? = nil, taskTitle: String? = nil, accessToken: String) async -> ChatRoom? {
        error = nil
        let chatId = Self.chatId(currentUserId, otherUserId)

        // Try fetching first
        var get = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        get.queryItems = [URLQueryItem(name: "id", value: "eq.\(chatId)"), URLQueryItem(name: "select", value: "*")]
        var getReq = URLRequest(url: get.url!)
        getReq.setValue(anonKey, forHTTPHeaderField: "apikey")
        getReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, http) = await sendAuthed(getReq, accessToken: accessToken),
           (200..<300).contains(http.statusCode),
           let rows = try? JSONDecoder().decode([ChatRoom].self, from: data),
           let existing = rows.first {
            return existing
        }

        // Create
        var post = URLRequest(url: baseURL.appendingPathComponent("rest/v1/chats"))
        post.httpMethod = "POST"
        post.setValue(anonKey, forHTTPHeaderField: "apikey")
        post.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("return=representation", forHTTPHeaderField: "Prefer")

        var body: [String: AnyEncodable] = [
            "id": AnyEncodable(chatId),
            "participants": AnyEncodable([currentUserId, otherUserId])
        ]
        if let taskId { body["task_id"] = AnyEncodable(taskId) }
        if let taskTitle { body["task_title"] = AnyEncodable(taskTitle) }
        post.httpBody = try? JSONEncoder().encode(body)

        guard let (data, http) = await sendAuthed(post, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatRoom].self, from: data),
              let created = rows.first
        else {
            if error == nil { error = "Не удалось создать чат. Попробуй ещё раз." }
            return nil
        }
        return created
    }

    /// Uploads a binary attachment to the private `chat-media` bucket. The
    /// database stores a stable public-shaped identifier; reads always exchange
    /// that identifier for a short-lived signed URL.
    func uploadAttachment(
        chatId: String,
        currentUserId: String,
        data: Data,
        mime: String,
        ext: String,
        accessToken: String
    ) async -> String? {
        guard ChatMediaPolicy.accepts(byteCount: data.count, mime: mime) else {
            error = "Файл пустой, слишком большой или имеет неподдерживаемый формат."
            return nil
        }
        guard let path = ChatMediaPolicy.uploadObjectPath(
            chatID: chatId,
            userID: currentUserId,
            fileExtension: ext
        ), let uploadURL = storageURL(pathPrefix: "/storage/v1/object/chat-media/", objectPath: path) else {
            error = "Некорректный путь вложения."
            return nil
        }
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue("3600", forHTTPHeaderField: "Cache-Control")
        req.httpBody = data
        guard let (_, http) = await sendAuthed(req, accessToken: accessToken),
              (200..<300).contains(http.statusCode) else {
            if error == nil { error = "Не удалось загрузить файл." }
            return nil
        }
        return ChatMediaPolicy.canonicalURL(objectPath: path, baseURL: baseURL)?.absoluteString
    }

    /// Video attachments use the same pinned TUS implementation as CourseUP.
    /// It resumes interrupted transfers and asks the caller for a fresh JWT on
    /// every request instead of freezing one token for a long upload.
    func uploadVideoAttachment(
        chatId: String,
        currentUserId: String,
        fileURL: URL,
        mime: String,
        ext: String,
        accessToken: String,
        accessTokenProvider: @escaping SupabaseResumableVideoUploader.AccessTokenProvider,
        progress: @escaping SupabaseResumableVideoUploader.ProgressHandler
    ) async -> String? {
        error = nil
        guard fileURL.isFileURL,
              let byteCount = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              ChatMediaPolicy.accepts(byteCount: byteCount, mime: mime)
        else {
            error = "Видео пустое, превышает 47 МБ или имеет неподдерживаемый формат."
            return nil
        }
        guard let objectPath = ChatMediaPolicy.uploadObjectPath(
            chatID: chatId,
            userID: currentUserId,
            fileExtension: ext
        ) else {
            error = "Некорректный путь вложения."
            return nil
        }

        do {
            let uploader = SupabaseResumableVideoUploader(
                baseURL: baseURL,
                anonKey: anonKey
            )
            return try await uploader.upload(
                fileURL: fileURL,
                bucketName: ChatMediaPolicy.bucket,
                objectName: objectPath,
                contentType: mime,
                accessToken: accessToken,
                accessTokenProvider: accessTokenProvider,
                progress: progress
            ).absoluteString
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Exchanges the stable media identifier stored in Postgres for a signed
    /// Storage URL. The cache is user-scoped, short-lived and bounded so a
    /// previous account's token can never be reused after sign-out.
    func signedMediaURL(
        canonicalURL: String,
        chatId: String,
        currentUserId: String,
        accessToken: String,
        forceRefresh: Bool = false
    ) async -> URL? {
        error = nil
        guard let host = baseURL.host,
              let objectPath = ChatMediaPolicy.objectPath(
                fromCanonicalURL: canonicalURL,
                expectedHost: host,
                expectedChatID: chatId
              ),
              ChatMediaPolicy.safePathComponent(currentUserId) != nil
        else {
            error = "Небезопасная ссылка вложения."
            return nil
        }

        let cacheKey = "\(currentUserId)|\(objectPath)"
        let now = Date()
        if forceRefresh {
            Self.signedMediaCache.removeValue(forKey: cacheKey)
        } else if var cached = Self.signedMediaCache[cacheKey], cached.expiresAt > now {
            cached.lastAccessAt = now
            Self.signedMediaCache[cacheKey] = cached
            return cached.url
        } else {
            Self.signedMediaCache.removeValue(forKey: cacheKey)
        }

        guard let signURL = storageURL(
            pathPrefix: "/storage/v1/object/sign/chat-media/",
            objectPath: objectPath
        ) else {
            error = "Некорректный путь вложения."
            return nil
        }
        var request = URLRequest(url: signURL)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["expiresIn": signedMediaLifetimeSeconds]
        )

        guard let (data, http) = await sendAuthed(request, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSignedURL = (payload["signedURL"] as? String) ?? (payload["signedUrl"] as? String),
              let signedURL = validatedSignedURL(rawSignedURL, objectPath: objectPath)
        else {
            if error == nil { error = "Не удалось открыть вложение." }
            return nil
        }

        Self.signedMediaCache[cacheKey] = CachedSignedMedia(
            url: signedURL,
            expiresAt: now.addingTimeInterval(signedMediaCacheTTL),
            lastAccessAt: now
        )
        pruneSignedMediaCache()
        return signedURL
    }

    func invalidateSignedMedia(canonicalURL: String, chatId: String, currentUserId: String) {
        guard let host = baseURL.host,
              let objectPath = ChatMediaPolicy.objectPath(
                fromCanonicalURL: canonicalURL,
                expectedHost: host,
                expectedChatID: chatId
              )
        else { return }
        Self.signedMediaCache.removeValue(forKey: "\(currentUserId)|\(objectPath)")
    }

    /// Removes a newly uploaded canonical object when the subsequent message
    /// insert fails. Legacy paths are deliberately excluded: cleanup must
    /// never delete another client's historical attachment by accident.
    func deleteUploadedAttachment(
        canonicalURL: String,
        chatId: String,
        currentUserId: String,
        accessToken: String
    ) async {
        guard let host = baseURL.host,
              let objectPath = ChatMediaPolicy.objectPath(
                fromCanonicalURL: canonicalURL,
                expectedHost: host,
                expectedChatID: chatId
              )
        else { return }
        let components = objectPath.split(separator: "/").map(String.init)
        guard components.count == 3,
              components[0] == ChatMediaPolicy.safePathComponent(chatId),
              components[1] == ChatMediaPolicy.safePathComponent(currentUserId),
              let deleteURL = storageURL(
                pathPrefix: "/storage/v1/object/chat-media/",
                objectPath: objectPath
              )
        else { return }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = await sendAuthed(request, accessToken: accessToken)
    }

    private func storageURL(pathPrefix: String, objectPath: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = pathPrefix + objectPath
        components.query = nil
        components.fragment = nil
        return components.url
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
              components.percentEncodedPath == "/storage/v1/object/sign/chat-media/\(objectPath)",
              components.queryItems?.contains(where: { $0.name == "token" && $0.value?.isEmpty == false }) == true
        else { return nil }
        return components.url
    }

    private func pruneSignedMediaCache() {
        let now = Date()
        Self.signedMediaCache = Self.signedMediaCache.filter { $0.value.expiresAt > now }
        guard Self.signedMediaCache.count > Self.signedMediaCacheLimit else { return }
        let overflow = Self.signedMediaCache.count - Self.signedMediaCacheLimit
        let oldestKeys = Self.signedMediaCache
            .sorted { $0.value.lastAccessAt < $1.value.lastAccessAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys { Self.signedMediaCache.removeValue(forKey: key) }
    }

    /// Inserts an image, audio or video message with a canonical media URL.
    @discardableResult
    func sendMedia(chatId: String, currentUserId: String, type: String, mediaUrl: String, mime: String, accessToken: String) async -> ChatMessageRow? {
        error = nil
        guard ["image", "audio", "video"].contains(type),
              let host = baseURL.host,
              ChatMediaPolicy.objectPath(
                fromCanonicalURL: mediaUrl,
                expectedHost: host,
                expectedChatID: chatId
              ) != nil
        else {
            error = "Небезопасная ссылка вложения."
            return nil
        }
        var post = URLRequest(url: baseURL.appendingPathComponent("rest/v1/messages"))
        post.httpMethod = "POST"
        post.setValue(anonKey, forHTTPHeaderField: "apikey")
        post.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let body: [String: AnyEncodable] = [
            "chat_id": AnyEncodable(chatId),
            "sender_id": AnyEncodable(currentUserId),
            "type": AnyEncodable(type),
            "media_url": AnyEncodable(mediaUrl),
            "media_mime": AnyEncodable(mime)
        ]
        post.httpBody = try? JSONEncoder().encode(body)
        guard let (data, http) = await sendAuthed(post, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatMessageRow].self, from: data),
              let inserted = rows.first
        else {
            if error == nil { error = "Не удалось отправить файл." }
            return nil
        }
        // Bump chat preview
        let preview = type == "image"
            ? "📷 Фото"
            : type == "audio" ? "🎤 Голосовое" : "🎬 Видео"
        var pURL = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        pURL.queryItems = [URLQueryItem(name: "id", value: "eq.\(chatId)")]
        var patch = URLRequest(url: pURL.url!)
        patch.httpMethod = "PATCH"
        patch.setValue(anonKey, forHTTPHeaderField: "apikey")
        patch.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bumpBody: [String: AnyEncodable] = [
            "last_message": AnyEncodable(preview),
            "last_message_at": AnyEncodable(ISO8601DateFormatter().string(from: Date()))
        ]
        patch.httpBody = try? JSONEncoder().encode(bumpBody)
        _ = await sendAuthed(patch, accessToken: accessToken)
        return inserted
    }

    @discardableResult
    func sendTaskCard(chatId: String, currentUserId: String, task: HubTask, accessToken: String) async -> ChatMessageRow? {
        error = nil
        let payload = ChatTaskCardPayload(task: task)
        var post = URLRequest(url: baseURL.appendingPathComponent("rest/v1/messages"))
        post.httpMethod = "POST"
        post.setValue(anonKey, forHTTPHeaderField: "apikey")
        post.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let body: [String: AnyEncodable] = [
            "chat_id": AnyEncodable(chatId),
            "sender_id": AnyEncodable(currentUserId),
            "type": AnyEncodable("task_card"),
            "content": AnyEncodable(payload.encodedString())
        ]
        post.httpBody = try? JSONEncoder().encode(body)

        guard let (data, http) = await sendAuthed(post, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatMessageRow].self, from: data),
              let inserted = rows.first
        else {
            if error == nil { error = "Не удалось отправить задание в чат." }
            return nil
        }

        var patchURL = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        patchURL.queryItems = [URLQueryItem(name: "id", value: "eq.\(chatId)")]
        var patch = URLRequest(url: patchURL.url!)
        patch.httpMethod = "PATCH"
        patch.setValue(anonKey, forHTTPHeaderField: "apikey")
        patch.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bumpBody: [String: AnyEncodable] = [
            "last_message": AnyEncodable(payload.preview),
            "last_message_at": AnyEncodable(ISO8601DateFormatter().string(from: Date()))
        ]
        patch.httpBody = try? JSONEncoder().encode(bumpBody)
        _ = await sendAuthed(patch, accessToken: accessToken)

        return inserted
    }

    /// Sends a text message, then bumps chats.last_message / last_message_at.
    /// Sets `self.error` on failure so the UI can show a real reason instead of a dead spinner.
    @discardableResult
    func sendText(chatId: String, currentUserId: String, text: String, accessToken: String, previewText: String? = nil) async -> ChatMessageRow? {
        error = nil
        var post = URLRequest(url: baseURL.appendingPathComponent("rest/v1/messages"))
        post.httpMethod = "POST"
        post.setValue(anonKey, forHTTPHeaderField: "apikey")
        post.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let body: [String: AnyEncodable] = [
            "chat_id": AnyEncodable(chatId),
            "sender_id": AnyEncodable(currentUserId),
            "type": AnyEncodable("text"),
            "content": AnyEncodable(text)
        ]
        post.httpBody = try? JSONEncoder().encode(body)

        guard let (data, http) = await sendAuthed(post, accessToken: accessToken),
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([ChatMessageRow].self, from: data),
              let inserted = rows.first
        else {
            if error == nil { error = "Не удалось отправить сообщение." }
            return nil
        }

        // Bump chat preview (best effort — message already sent)
        var patchURL = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false)!
        patchURL.queryItems = [URLQueryItem(name: "id", value: "eq.\(chatId)")]
        var patch = URLRequest(url: patchURL.url!)
        patch.httpMethod = "PATCH"
        patch.setValue(anonKey, forHTTPHeaderField: "apikey")
        patch.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedPreview = previewText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (trimmedPreview?.isEmpty == false) ? (trimmedPreview ?? text) : text
        let bumpBody: [String: AnyEncodable] = [
            "last_message": AnyEncodable(preview),
            "last_message_at": AnyEncodable(ISO8601DateFormatter().string(from: Date()))
        ]
        patch.httpBody = try? JSONEncoder().encode(bumpBody)
        _ = await sendAuthed(patch, accessToken: accessToken)

        return inserted
    }
}
