import Foundation

struct SupabaseUser: Decodable {
    let id: String
    let email: String?
}

struct SupabaseSession: Decodable {
    let accessToken: String
    let refreshToken: String?
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

@MainActor
final class SupabaseClient {
    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String

    private(set) var sessionGeneration: UInt64 = 0
    var accessToken: String? {
        didSet {
            if accessToken != oldValue {
                sessionGeneration &+= 1
            }
        }
    }
    var refreshToken: String? {
        didSet {
            if refreshToken != oldValue {
                sessionGeneration &+= 1
            }
        }
    }

    /// Hook for the Auth layer to persist refreshed tokens to UserDefaults.
    var onSessionRefreshed: ((SupabaseSession) -> Void)?

    private struct RefreshFlight {
        let id: UUID
        let refreshToken: String
        let sessionGeneration: UInt64
        let task: Task<SupabaseSession, Error>
    }
    private var refreshFlight: RefreshFlight?

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
    }

    func signInWithEmailPassword(email: String, password: String) async throws -> SupabaseSession {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])
        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)
        return try JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    func signUpWithEmailPassword(email: String, password: String) async throws -> SupabaseSession {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/v1/signup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])
        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)
        return try JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    func signInWithApple(identityToken: String, nonce: String) async throws -> SupabaseSession {
        try await signInWithIdToken(provider: "apple", idToken: identityToken, nonce: nonce)
    }

    /// Trades a Google idToken (from GIDSignIn iOS SDK) for a Supabase session.
    /// Requires "Skip nonce checks" = ON in Supabase Auth → Google provider.
    func signInWithGoogle(idToken: String) async throws -> SupabaseSession {
        try await signInWithIdToken(provider: "google", idToken: idToken)
    }

    private func signInWithIdToken(
        provider: String,
        idToken: String,
        nonce: String? = nil
    ) async throws -> SupabaseSession {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        var body: [String: String] = [
            "provider": provider,
            "id_token": idToken
        ]
        if let nonce, !nonce.isEmpty { body["nonce"] = nonce }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)
        return try JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    /// Fetches the authenticated user info using a raw access token.
    /// Used after OAuth flows where we only have the token, not a full session payload.
    func fetchUser(accessToken: String) async throws -> SupabaseUser {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/v1/user"))
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)
        return try JSONDecoder().decode(SupabaseUser.self, from: data)
    }

    func refreshSession() async throws -> SupabaseSession {
        guard let refresh = refreshToken else {
            throw SupabaseError.notAuthenticated
        }
        let expectedGeneration = sessionGeneration

        if let flight = refreshFlight,
           flight.refreshToken == refresh,
           flight.sessionGeneration == expectedGeneration {
            return try await flight.task.value
        }

        let flightID = UUID()
        let task = Task<SupabaseSession, Error> { [weak self] in
            guard let self else { throw SupabaseError.notAuthenticated }
            return try await self.performRefresh(
                refreshToken: refresh,
                expectedGeneration: expectedGeneration
            )
        }
        refreshFlight = RefreshFlight(
            id: flightID,
            refreshToken: refresh,
            sessionGeneration: expectedGeneration,
            task: task
        )

        do {
            let refreshed = try await task.value
            if refreshFlight?.id == flightID { refreshFlight = nil }
            return refreshed
        } catch {
            if refreshFlight?.id == flightID { refreshFlight = nil }
            throw error
        }
    }

    private func performRefresh(
        refreshToken refresh: String,
        expectedGeneration: UInt64
    ) async throws -> SupabaseSession {

        var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try ensureOK(response: response, data: data)
        let refreshedSession = try JSONDecoder().decode(
            SupabaseSession.self,
            from: data
        )
        guard sessionGeneration == expectedGeneration,
              refreshToken == refresh
        else {
            throw SupabaseError.staleSession
        }

        accessToken = refreshedSession.accessToken
        refreshToken = refreshedSession.refreshToken ?? refresh
        onSessionRefreshed?(refreshedSession)
        return refreshedSession
    }

    func deleteOwnAccount() async throws {
        try await runAuthed { token in
            let url = self.baseURL.appendingPathComponent("rest/v1/rpc/delete_own_account")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(self.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = "{}".data(using: .utf8)
            return request
        }
    }

    func generateImage(
        prompt: String,
        provider: ImageGenerationProvider,
        category: ImageGenerationCategory,
        quantity: Int = 1,
        size: ImageGenerationSize = .square,
        referenceImages: [ImageGenerationReference] = [],
        idempotencyKey: String? = nil
    ) async throws -> GeneratedImage {
        let body = try imageRequestBody(
            prompt: prompt,
            provider: provider,
            category: category,
            quantity: quantity,
            size: size,
            referenceImages: referenceImages
        )
        let data = try await runAuthed { token in
            self.imageRequest(
                body: body,
                accessToken: token,
                idempotencyKey: idempotencyKey
            )
        }
        return try JSONDecoder().decode(GeneratedImage.self, from: data)
    }

    /// Paid multi-step flows use the access token captured for the account
    /// that started the operation. This path intentionally never reads or
    /// refreshes the mutable shared session after the request begins.
    func generateImageWithAccessToken(
        prompt: String,
        provider: ImageGenerationProvider,
        category: ImageGenerationCategory,
        quantity: Int = 1,
        size: ImageGenerationSize = .square,
        referenceImages: [ImageGenerationReference] = [],
        idempotencyKey: String? = nil,
        accessToken: String
    ) async throws -> GeneratedImage {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw SupabaseError.notAuthenticated
        }
        let body = try imageRequestBody(
            prompt: prompt,
            provider: provider,
            category: category,
            quantity: quantity,
            size: size,
            referenceImages: referenceImages
        )
        let request = imageRequest(
            body: body,
            accessToken: token,
            idempotencyKey: idempotencyKey
        )
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try ensureOK(response: response, data: data)
        return try JSONDecoder().decode(GeneratedImage.self, from: data)
    }

    // MARK: - Auth-aware request runner with auto-refresh on 401

    @discardableResult
    private func runAuthed(_ build: @escaping (String) -> URLRequest) async throws -> Data {
        guard let token = accessToken else { throw SupabaseError.notAuthenticated }
        let expectedGeneration = sessionGeneration
        let request = build(token)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, http.statusCode == 401, refreshToken != nil {
            // Token expired — refresh once and retry
            guard sessionGeneration == expectedGeneration,
                  accessToken == token
            else {
                throw SupabaseError.staleSession
            }
            let refreshedSession = try await refreshSession()
            try Task.checkCancellation()
            guard accessToken == refreshedSession.accessToken else {
                throw SupabaseError.staleSession
            }
            let newToken = refreshedSession.accessToken
            let retryRequest = build(newToken)
            let (retryData, retryResponse) = try await session.data(for: retryRequest)
            try Task.checkCancellation()
            try ensureOK(response: retryResponse, data: retryData)
            return retryData
        }

        try ensureOK(response: response, data: data)
        return data
    }

    private func imageRequestBody(
        prompt: String,
        provider: ImageGenerationProvider,
        category: ImageGenerationCategory,
        quantity: Int,
        size: ImageGenerationSize,
        referenceImages: [ImageGenerationReference]
    ) throws -> Data {
        guard ImageGenerationReferencePolicy.accepts(referenceImages) else {
            throw SupabaseError.invalidMediaPayload
        }
        var payload: [String: Any] = [
            "prompt": prompt,
            "provider": provider.provider,
            "model": provider.rawValue,
            "category": category.id,
            "quantity": quantity,
            "size": size.rawValue
        ]
        if !referenceImages.isEmpty {
            payload["images"] = referenceImages.map { image in
                [
                    "mimeType": image.mimeType,
                    "data": image.base64,
                    "role": image.role.rawValue
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func imageRequest(
        body: Data,
        accessToken: String,
        idempotencyKey: String?
    ) -> URLRequest {
        let url = baseURL.appendingPathComponent("functions/v1/generate-image")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = body
        return request
    }

    private func ensureOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.serverError(status: http.statusCode, body: body)
        }
    }
}

enum ImageGenerationReferenceRole: String, CaseIterable {
    case sourceImage = "source_image"
    case mainProduct = "main_product"
    case logo
    case styleReference = "style_reference"
    case heroFace = "hero_face"
    case characterReference = "character_reference"
}

struct ImageGenerationReference {
    let mimeType: String
    let base64: String
    let role: ImageGenerationReferenceRole

    init(
        mimeType: String,
        base64: String,
        role: ImageGenerationReferenceRole = .styleReference
    ) {
        self.mimeType = mimeType
        self.base64 = base64
        self.role = role
    }
}

enum ImageGenerationReferencePolicy {
    static let maximumCount = 6
    static let maximumDecodedBytesPerImage = 8 * 1_024 * 1_024
    static let maximumDecodedBytesTotal = 24 * 1_024 * 1_024

    static func accepts(_ references: [ImageGenerationReference]) -> Bool {
        guard references.count <= maximumCount else { return false }
        var total = 0
        for reference in references {
            guard ["image/jpeg", "image/png", "image/webp"].contains(reference.mimeType.lowercased()) else {
                return false
            }
            // Base64 decoded size is at most 3/4 of its encoded byte count.
            let decodedBytes = reference.base64.utf8.count * 3 / 4
            guard decodedBytes > 0,
                  decodedBytes <= maximumDecodedBytesPerImage
            else { return false }
            total += decodedBytes
            guard total <= maximumDecodedBytesTotal else { return false }
        }
        return true
    }
}

struct GeneratedImage: Decodable {
    let imageBase64: String
    let imageBase64s: [String]?
    let prompt: String
    let provider: String?
    let model: String?
    let category: String?
    let size: String?
    let quantity: Int?
    let costCredits: Int?
    let creditsRemaining: Int?
    let assetIds: [String]?
}

enum SupabaseError: LocalizedError {
    case notAuthenticated
    /// An operation started under an older account/session. It must be
    /// discarded without clearing the newer session now stored by the app.
    case staleSession
    case invalidResponse
    case serverError(status: Int, body: String)
    case invalidMediaPayload

    /// Only credential rejection invalidates the local session. Connectivity
    /// failures and server outages must never sign the user out.
    var invalidatesSession: Bool {
        switch self {
        case .notAuthenticated:
            return true
        case .staleSession:
            return false
        case .serverError(let status, _):
            return status == 400 || status == 401
        case .invalidResponse:
            return false
        case .invalidMediaPayload:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in."
        case .staleSession:
            return "The signed-in account changed while the request was running."
        case .invalidResponse:
            return "Invalid response from server."
        case .invalidMediaPayload:
            return "Too many reference images or the files are too large."
        case .serverError(let status, let body):
            if let message = Self.serverMessage(from: body) {
                return message
            }
            return "Server error \(status)."
        }
    }

    private static func serverMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }

        switch payload["error"] as? String {
        case "prompt_required":
            return "Write a prompt or add a photo."
        case "provider_not_configured":
            return "Image provider is not configured."
        case "insufficient_credits":
            return "Not enough credits."
        case "credit_service_unavailable":
            return "Credit service is unavailable."
        case "provider_error":
            return "Image provider error."
        default:
            return nil
        }
    }
}
