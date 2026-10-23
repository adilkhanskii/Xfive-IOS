import Foundation

struct AppNotification: Codable, Identifiable, Equatable {
    let id: String
    let userId: String
    let actorId: String?
    let type: String
    let title: String
    let body: String?
    let objectType: String?
    let objectId: String?
    let isRead: Bool
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, body
        case userId = "user_id"
        case actorId = "actor_id"
        case objectType = "object_type"
        case objectId = "object_id"
        case isRead = "is_read"
        case createdAt = "created_at"
    }
}

private struct NotificationChatRow: Codable {
    let id: String
    let taskTitle: String?
    let lastMessage: String?
    let lastMessageAt: String?
    let unread: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case id, unread
        case taskTitle = "task_title"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
    }
}

@MainActor
final class NotificationsService: ObservableObject {
    @Published private(set) var items: [AppNotification] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var baseURL: URL { X5Config.supabaseBaseURL }
    private var anonKey: String { X5Config.supabaseAnonKey }

    func load(userId: String, accessToken: String) async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        let persisted = await loadPersistedNotifications(userId: userId, accessToken: accessToken)
        let unreadChats = await loadUnreadChatNotifications(userId: userId, accessToken: accessToken)
        items = mergeNotifications(persisted: persisted, local: unreadChats)
    }

    func markRead(_ notification: AppNotification, accessToken: String) async {
        guard !notification.isRead else { return }
        guard !notification.id.hasPrefix("local-chat-") else { return }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/notifications"), resolvingAgainstBaseURL: false) else {
            return
        }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(notification.id)")]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["is_read": true])
        _ = try? await URLSession.shared.data(for: request)
        if let index = items.firstIndex(where: { $0.id == notification.id }) {
            items[index] = AppNotification(
                id: notification.id,
                userId: notification.userId,
                actorId: notification.actorId,
                type: notification.type,
                title: notification.title,
                body: notification.body,
                objectType: notification.objectType,
                objectId: notification.objectId,
                isRead: true,
                createdAt: notification.createdAt
            )
        }
    }

    private func loadPersistedNotifications(userId: String, accessToken: String) async -> [AppNotification] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/notifications"), resolvingAgainstBaseURL: false) else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "80")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return []
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "Notifications", code: http.statusCode)
            }
            return try JSONDecoder().decode([AppNotification].self, from: data)
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    private func loadUnreadChatNotifications(userId: String, accessToken: String) async -> [AppNotification] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/chats"), resolvingAgainstBaseURL: false) else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "participants", value: "cs.{\(userId)}"),
            URLQueryItem(name: "select", value: "id,task_title,last_message,last_message_at,unread"),
            URLQueryItem(name: "order", value: "last_message_at.desc.nullslast"),
            URLQueryItem(name: "limit", value: "40")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let rows = try JSONDecoder().decode([NotificationChatRow].self, from: data)
            return rows.compactMap { row in
                guard !ChatsLocalState.isMuted(row.id),
                      (row.unread?[userId] ?? 0) > 0
                else { return nil }
                let title = row.taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AppNotification(
                    id: "local-chat-\(row.id)",
                    userId: userId,
                    actorId: nil,
                    type: "message",
                    title: title?.isEmpty == false ? title ?? "New message" : "New message",
                    body: row.lastMessage,
                    objectType: "chat",
                    objectId: row.id,
                    isRead: false,
                    createdAt: row.lastMessageAt
                )
            }
        } catch {
            return []
        }
    }

    private func mergeNotifications(persisted: [AppNotification], local: [AppNotification]) -> [AppNotification] {
        var byId: [String: AppNotification] = [:]
        for item in local {
            byId[item.id] = item
        }
        for item in persisted {
            if item.type == "message", item.objectType == "chat", let chatId = item.objectId {
                byId.removeValue(forKey: "local-chat-\(chatId)")
            }
            byId[item.id] = item
        }
        return byId.values.sorted { lhs, rhs in
            notificationDate(lhs.createdAt) > notificationDate(rhs.createdAt)
        }
    }

    private func notificationDate(_ iso: String?) -> Date {
        guard let iso, !iso.isEmpty else { return .distantPast }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }
}
