import Foundation

/// Жалоба на результат ИИ прямо из приложения — правила Apple и Google Play
/// об ИИ-контенте: пользователь сообщает об оскорбительном результате, не выходя
/// из приложения. Та же таблица `public.reports`, что у веба и Android
/// (RLS: вставка только своей строки), без миграции.
enum AIContentReportReason: String, CaseIterable, Identifiable, Sendable {
    case sexual
    case violence
    case hate
    case deepfake
    case other

    var id: String { rawValue }
}

struct AIContentReport: Equatable, Sendable {
    /// Откуда жалоба: image, video, voice, startup-chat…
    var tool: String
    var reason: AIContentReportReason
    var comment: String
    var contentURL: String?
    var contentText: String?
    var prompt: String?
}

extension AIContentReport {
    /// Ссылка на результат для жалобы: id ассета надёжнее подписанной ссылки, которая истекает.
    static func reference(assetID: String?, url: URL? = nil) -> String? {
        if let assetID, !assetID.isEmpty { return "asset:\(assetID)" }
        return url?.absoluteString
    }
}

enum AIContentReportServiceError: Error, Equatable {
    case http(statusCode: Int)
}

struct AIContentReportService {
    /// Тот же адрес пушей, что у веба (`pushToMany` → send-push).
    static let defaultPushURL = URL(string: "https://api-ylicmzq4eq-uc.a.run.app/send-push")!
    static let pushTitle = "⚑ Жалоба на ИИ-контент"

    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String
    private let pushURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey,
        pushURL: URL = AIContentReportService.defaultPushURL
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.pushURL = pushURL
    }

    /// Строка для `reports`: reported_user_id обязателен — для ИИ-контента это сам
    /// автор запроса; подробности — JSON в `reason`, как у веба.
    static func rowBody(for report: AIContentReport, userId: String) throws -> Data {
        let details: [String: Any] = [
            "kind": "ai_content",
            "tool": report.tool,
            "reason": report.reason.rawValue,
            "comment": String(trimmed(report.comment).prefix(1_000)),
            "content_url": clipped(report.contentURL, 2_000),
            "content_text": clipped(report.contentText, 2_000),
            "prompt": clipped(report.prompt, 1_000),
            "page": "ios",
        ]
        let detailsData = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
        let row: [String: Any] = [
            "reporter_id": userId,
            "reported_user_id": userId,
            "reported_user_name": "AI:\(report.tool)",
            "reason": String(decoding: detailsData, as: UTF8.self),
        ]
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    }

    static func pushBody(for report: AIContentReport) -> String {
        let comment = trimmed(report.comment)
        let tail = comment.isEmpty ? "" : " — " + String(comment.prefix(80))
        return "\(report.tool): \(report.reason.rawValue)\(tail)"
    }

    func send(_ report: AIContentReport, userId: String, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/reports"))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.rowBody(for: report, userId: userId)

        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw AIContentReportServiceError.http(statusCode: status)
        }
    }

    /// Пуш разработчикам, как на вебе. Зовётся после сохранения жалобы и не ждётся
    /// экраном: сбой пуша жалобу не отменяет.
    func notifyDevelopers(_ report: AIContentReport) async {
        let body = Self.pushBody(for: report)
        for userId in Roles.developerUserIds.sorted() {
            var request = URLRequest(url: pushURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "to_user_id": userId,
                "title": Self.pushTitle,
                "body": body,
                "data": [String: String](),
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await session.data(for: request)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(_ text: String?, _ limit: Int) -> Any {
        guard let text else { return NSNull() }
        let clean = trimmed(text)
        return clean.isEmpty ? NSNull() : String(clean.prefix(limit))
    }
}
