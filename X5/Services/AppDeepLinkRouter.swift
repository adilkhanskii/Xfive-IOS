import Foundation

enum AppDeepLink: Equatable {
    case hubTask(id: String)
    case chat(id: String)
}

enum AppDeepLinkParser {
    static func parse(userInfo: [AnyHashable: Any]) -> AppDeepLink? {
        parse(dictionary: stringify(userInfo))
    }

    static func parse(notification: AppNotification) -> AppDeepLink? {
        guard let objectId = clean(notification.objectId) else { return nil }
        switch clean(notification.objectType)?.lowercased() {
        case "task", "hub_task", "task_response":
            return .hubTask(id: objectId)
        case "chat", "message":
            return .chat(id: objectId)
        default:
            return nil
        }
    }

    private static func parse(dictionary: [String: Any]) -> AppDeepLink? {
        for key in ["task_id", "taskId", "hub_task_id", "hubTaskId"] {
            if let id = clean(dictionary[key]) { return .hubTask(id: id) }
        }
        for key in ["chat_id", "chatId"] {
            if let id = clean(dictionary[key]) { return .chat(id: id) }
        }

        let objectType = clean(dictionary["object_type"] ?? dictionary["objectType"])?.lowercased()
        if let objectId = clean(dictionary["object_id"] ?? dictionary["objectId"]) {
            switch objectType {
            case "task", "hub_task", "task_response": return .hubTask(id: objectId)
            case "chat", "message": return .chat(id: objectId)
            default: break
            }
        }

        for key in ["deep_link", "deepLink", "url"] {
            if let raw = clean(dictionary[key]), let parsed = parse(urlString: raw) {
                return parsed
            }
        }

        for key in ["data", "payload", "custom"] {
            if let nested = dictionary[key] as? [String: Any],
               let parsed = parse(dictionary: nested) {
                return parsed
            }
            if let nested = dictionary[key] as? [AnyHashable: Any],
               let parsed = parse(dictionary: stringify(nested)) {
                return parsed
            }
            if let raw = dictionary[key] as? String,
               let data = raw.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let parsed = parse(dictionary: nested) {
                return parsed
            }
        }
        return nil
    }

    private static func parse(urlString: String) -> AppDeepLink? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents)
            .filter { $0 != "/" && !$0.isEmpty }
        if let taskIndex = parts.firstIndex(where: { $0 == "task" || $0 == "tasks" }),
           parts.indices.contains(taskIndex + 1),
           let id = clean(parts[taskIndex + 1]) {
            return .hubTask(id: id)
        }
        if let chatIndex = parts.firstIndex(where: { $0 == "chat" || $0 == "chats" }),
           parts.indices.contains(chatIndex + 1),
           let id = clean(parts[chatIndex + 1]) {
            return .chat(id: id)
        }
        return nil
    }

    private static func stringify(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
            guard let key = key as? String else { return nil }
            return (key, value)
        })
    }

    private static func clean(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return nil }
        return trimmed
    }
}

@MainActor
final class AppDeepLinkRouter: ObservableObject {
    static let shared = AppDeepLinkRouter()

    @Published private(set) var pendingHubTaskID: String?
    @Published private(set) var pendingChatID: String?

    func route(userInfo: [AnyHashable: Any]) {
        guard let link = AppDeepLinkParser.parse(userInfo: userInfo) else { return }
        route(link)
    }

    func route(_ link: AppDeepLink) {
        switch link {
        case .hubTask(let id):
            pendingChatID = nil
            pendingHubTaskID = id
        case .chat(let id):
            pendingHubTaskID = nil
            pendingChatID = id
        }
    }

    func consumeHubTask(id: String) {
        guard pendingHubTaskID == id else { return }
        pendingHubTaskID = nil
    }

    func consumeChat(id: String) {
        guard pendingChatID == id else { return }
        pendingChatID = nil
    }
}
