import Foundation
import Combine

struct ProfileOperationContext: Equatable {
    let userID: String
    let epoch: UUID
}

struct SocialLinks: Codable, Equatable, Hashable {
    var instagram: String?
    var telegram: String?
    var whatsapp: String?
    var tiktok: String?
    var youtube: String?
    var linkedin: String?
    var facebook: String?
}

struct UserProfile: Codable, Equatable, Identifiable {
    let id: String
    var name: String?
    var nickname: String?
    var email: String?
    var avatar: String?
    var bio: String?
    var services: [String]?
    var plan: String?               // free | lite | pro | max | black
    var credits: Int?
    var purchasedCourseIds: [String]?
    var purchasedLessonIds: [String]?
    var subscriptionType: String?
    var subscriptionDate: String?
    var subscriptionEndDate: String?
    var socialLinks: SocialLinks?
    var userRole: String?           // specialist | entrepreneur
    var specialistCategory: [String]?
    var showInHub: Bool?
    var isPublic: Bool?
    var signupNumber: Int?
    var language: String?
    var lastSeen: String?
    var isVerified: Bool?
    var verifiedUntil: String?
    var countryCode: String?
    var city: String?
    var registrationPlatform: String?
    var onboardingCompletedAt: String?
    /// Срок доступа к купленным курсам/урокам: ключ как в purchased_*_ids → ISO-дата конца.
    /// Не колонка profiles: грузится из course_access_expiry (30 дней, Адильхан 09.10),
    /// кодируется только в локальный кэш профиля. Ключа нет = старая покупка = навсегда.
    var accessExpiry: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, name, nickname, email, avatar, bio, services, plan, credits, language
        case purchasedCourseIds = "purchased_course_ids"
        case purchasedLessonIds = "purchased_lesson_ids"
        case subscriptionType = "subscription_type"
        case subscriptionDate = "subscription_date"
        case subscriptionEndDate = "subscription_end_date"
        case socialLinks = "social_links"
        case userRole = "user_role"
        case specialistCategory = "specialist_category"
        case showInHub = "show_in_hub"
        case isPublic = "is_public"
        case signupNumber = "signup_number"
        case lastSeen = "last_seen"
        case isVerified = "is_verified"
        case verifiedUntil = "verified_until"
        case countryCode = "country_code"
        case city
        case registrationPlatform = "registration_platform"
        case onboardingCompletedAt = "onboarding_completed_at"
        case accessExpiry = "x5_access_expiry"
    }

    /// timestamptz из Postgres («2026-11-08T14:30:00.123456+00:00») → Date.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    var displayName: String {
        if let n = Self.cleanDisplayName(name) { return n }
        if let n = Self.cleanDisplayName(nickname) { return n }
        if let e = email, let prefix = e.split(separator: "@").first, !prefix.isEmpty {
            let emailName = String(prefix).replacingOccurrences(of: ".", with: " ").capitalized
            if let n = Self.cleanDisplayName(emailName) { return n }
        }
        return "Xfive marketing"
    }

    private static func cleanDisplayName(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        guard !value.isEmpty, lower != "user", lower != "x5" else { return nil }
        return value
    }

    var planLabel: String {
        switch plan ?? "free" {
        case "lite": return "Lite"
        case "pro": return "Pro"
        case "max": return "Max"
        case "black": return "Black"
        default: return "Free"
        }
    }

    /// Paid access is active only while the server-recorded StoreKit period is
    /// active. Legacy paid profiles that predate expiration tracking keep their
    /// access; new verified transactions always include an end date.
    var isPro: Bool {
        Self.isPaidPlanActive(plan: plan, endDate: subscriptionEndDate)
    }

    static func isPaidPlanActive(plan: String?, endDate: String?) -> Bool {
        let normalizedPlan = plan?.lowercased()
        if normalizedPlan == "black" { return true }
        guard ["lite", "pro", "max"].contains(normalizedPlan ?? "") else { return false }
        guard let end = endDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !end.isEmpty
        else { return true }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiration = formatter.date(from: end) ?? ISO8601DateFormatter().date(from: end)
        return expiration.map { $0 > Date() } ?? false
    }

    /// True only if is_verified is set AND the paid period hasn't expired.
    var hasActiveVerifiedBadge: Bool {
        Self.isVerifiedBadgeActive(isVerified: isVerified, until: verifiedUntil)
    }

    static func isVerifiedBadgeActive(
        isVerified: Bool?,
        until untilStr: String?,
        now: Date = Date()
    ) -> Bool {
        guard isVerified == true, let untilStr else { return false }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let until = f.date(from: untilStr) ?? ISO8601DateFormatter().date(from: untilStr)
        guard let until else { return false }
        return until > now
    }
}

@MainActor
final class CurrentUser: ObservableObject {
    /// Server-side profile row. Setter posts `.x5ProfileDidUpdate` so dependent
    /// services (Subscription, etc.) reconcile their local cache to match the
    /// server — the single source of truth for plan / Pro state.
    ///
    /// Notification payload is intentionally narrow (`is_pro` only). Posting
    /// the full struct via the default NotificationCenter would expose PII
    /// (email, credits, push_token) to any in-process observer including
    /// linked third-party SDKs.
    ///
    /// Setter also persists the row to UserDefaults so the next launch can
    /// paint the profile instantly instead of flashing "User"/blank → real
    /// values once the server roundtrip finishes.
    @Published private(set) var profile: UserProfile? {
        didSet {
            NotificationCenter.default.post(
                name: .x5ProfileDidUpdate,
                object: nil,
                userInfo: ["is_pro": profile?.isPro ?? false]
            )
            persistCachedProfile()
        }
    }
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?

    private let cachedProfileKeyPrefix = "x5.profile.cache."
    private var lastCachedProfileId: String?

    private let baseURL = URL(string: "https://afwznqjpshybmqhlewmy.supabase.co")!
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmd3pucWpwc2h5Ym1xaGxld215Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzNTUxMTcsImV4cCI6MjA4NTkzMTExN30.p51iPiMEUSETS9Ot_qkmtA3IcqA23kadgoBLLQDXuL0"

    private var observer: AnyCancellable?
    private let session: URLSession
    private let sessionUserID: @MainActor () -> String?
    private var sessionEpoch = UUID()
    private var observedAccountID: String?

    init(
        session: URLSession = .shared,
        sessionUserID: @escaping @MainActor () -> String? = {
            UserDefaults.standard.string(forKey: "x5.session.user_id")
        },
        restoreCache: Bool = true
    ) {
        self.session = session
        self.sessionUserID = sessionUserID
        self.observedAccountID = sessionUserID()?.lowercased()
        // Restore the last cached profile synchronously so ProfileView renders
        // real values on cold launch instead of flashing "User"/empty defaults
        // for the seconds it takes the server fetch to come back.
        if restoreCache { restoreCachedProfile() }

        // Auth emits synchronously on MainActor before asynchronous cleanup.
        // Queuing another Task here can clear the NEXT signed-in user's profile.
        observer = NotificationCenter.default.publisher(for: .x5UserDidSignOut).sink { [weak self] _ in
            self?.invalidateProfileSession()
        }
    }

    private func invalidateProfileSession() {
        sessionEpoch = UUID()
        observedAccountID = nil
        profile = nil
        isLoading = false
        error = nil
    }

    func operationContext(for userID: String? = nil) -> ProfileOperationContext? {
        let activeID = sessionUserID()?.lowercased()
        if activeID != observedAccountID {
            invalidateProfileSession()
            observedAccountID = activeID
        }
        guard let activeID, userID == nil || userID?.lowercased() == activeID else { return nil }
        return ProfileOperationContext(userID: activeID, epoch: sessionEpoch)
    }

    func isCurrent(_ context: ProfileOperationContext?) -> Bool {
        guard let context else { return false }
        return context.epoch == sessionEpoch && sessionUserID()?.lowercased() == context.userID
    }

    /// A delayed paid operation must never borrow the next account's token,
    /// including when a 401 callback refreshes credentials after an await.
    func accessTokenForOperation(
        _ context: ProfileOperationContext,
        refresh: () async -> String?
    ) async -> String? {
        guard isCurrent(context) else { return nil }
        let token = await refresh()
        guard isCurrent(context) else { return nil }
        return token
    }

    private func commit(_ row: UserProfile, for context: ProfileOperationContext) -> Bool {
        guard isCurrent(context), row.id.lowercased() == context.userID else { return false }
        profile = row
        return true
    }

    private func restoreCachedProfile() {
        let defaults = UserDefaults.standard
        guard let sessionUserId = defaults.string(forKey: "x5.session.user_id")?.lowercased(),
              let data = defaults.data(forKey: cachedProfileKeyPrefix + sessionUserId),
              let cached = try? JSONDecoder().decode(UserProfile.self, from: data)
        else { return }
        guard cached.id.caseInsensitiveCompare(sessionUserId) == .orderedSame else {
            defaults.removeObject(forKey: cachedProfileKeyPrefix + sessionUserId)
            return
        }
        lastCachedProfileId = cached.id.lowercased()
        // Routing through the setter re-persists the same bytes (no-op write)
        // and re-broadcasts the cached plan — which is fine: Subscription
        // syncs to the cached state until the server fetch overrides it,
        // matching what's painted in the UI.
        self.profile = cached
    }

    private func persistCachedProfile() {
        let defaults = UserDefaults.standard
        if let profile, let data = try? JSONEncoder().encode(profile) {
            let profileId = profile.id.lowercased()
            defaults.set(data, forKey: cachedProfileKeyPrefix + profileId)
            lastCachedProfileId = profileId
            defaults.removeObject(forKey: "x5.profile.cache")
        } else if let lastCachedProfileId {
            defaults.removeObject(forKey: cachedProfileKeyPrefix + lastCachedProfileId)
            self.lastCachedProfileId = nil
        }
    }

    func applyCreditsRemaining(_ credits: Int, for context: ProfileOperationContext?) {
        guard isCurrent(context), var profile, profile.id.lowercased() == context?.userID else { return }
        profile.credits = credits
        self.profile = profile
    }

    /// Applies the server-authoritative result of the atomic course-purchase
    /// RPC so the course unlocks immediately while a full profile refresh is
    /// in flight. Failed business outcomes only reconcile the known balance.
    func applyCoursePurchase(_ response: CoursePurchaseResponse, for context: ProfileOperationContext?) {
        guard isCurrent(context), var profile, profile.id.lowercased() == context?.userID else { return }

        if let credits = response.creditsRemaining {
            profile.credits = credits
        }
        if response.grantsOwnership {
            var purchased = profile.purchasedCourseIds ?? []
            if !purchased.contains(response.courseId) {
                purchased.append(response.courseId)
            }
            profile.purchasedCourseIds = purchased
            // Новый срок 30 дней — сразу на экран, не дожидаясь перезагрузки профиля.
            if let expiresAt = response.accessExpiresAt {
                profile.accessExpiry = (profile.accessExpiry ?? [:]).merging([response.courseId: expiresAt]) { _, new in new }
            }
        }
        self.profile = profile
    }

    /// Applies the result of the atomic single-lesson RPC. Only the key the
    /// server reported storing is trusted, so a malformed success can never
    /// unlock a lesson the database did not actually grant. Fenced by the
    /// same operation context as course purchases so a response that lands
    /// after sign-out or an account switch is dropped.
    func applyLessonPurchase(_ response: LessonPurchaseResponse, for context: ProfileOperationContext?) {
        guard isCurrent(context), var profile, profile.id.lowercased() == context?.userID else { return }

        if let credits = response.creditsRemaining {
            profile.credits = credits
        }
        if response.grantsOwnership {
            var purchased = profile.purchasedLessonIds ?? []
            if !purchased.contains(response.lessonKey) {
                purchased.append(response.lessonKey)
            }
            profile.purchasedLessonIds = purchased
            if let expiresAt = response.accessExpiresAt {
                profile.accessExpiry = (profile.accessExpiry ?? [:]).merging([response.lessonKey: expiresAt]) { _, new in new }
            }
        }
        self.profile = profile
    }

    /// Loads (or refreshes) the current user's profile row using the access token.
    /// If the row does not exist yet, creates it with default values.
    @discardableResult
    func load(userId: String, accessToken: String) async -> Bool {
        guard let context = operationContext(for: userId) else { return false }
        isLoading = true
        defer { if isCurrent(context) { isLoading = false } }
        error = nil
        do {
            var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "*")
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard isCurrent(context) else { return false }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "CurrentUser", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            let rows = try JSONDecoder().decode([UserProfile].self, from: data)
            if var row = rows.first {
                // Сроки доступа живут в другой таблице: держим прежние, пока грузятся свежие,
                // чтобы надпись «открыто до …» не мигала.
                if row.id.caseInsensitiveCompare(profile?.id ?? "") == .orderedSame {
                    row.accessExpiry = profile?.accessExpiry
                }
                // Сами сроки грузит экран курса (refreshAccessExpiry): загрузка профиля
                // остаётся одним запросом — на этом держится защита от гонок аккаунтов.
                return commit(row, for: context)
            } else {
                // Profile row missing — create one (covers users registered before the
                // auth.users -> profiles Postgres trigger existed).
                return await ensureProfile(userId: userId, accessToken: accessToken, context: context)
            }
        } catch {
            if isCurrent(context) { self.error = error.localizedDescription }
            return false
        }
    }

    private struct AccessExpiryRow: Decodable {
        let accessKey: String
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case accessKey = "access_key"
            case expiresAt = "expires_at"
        }
    }

    /// Сроки доступа для текущего аккаунта — зовёт экран курса при открытии.
    func refreshAccessExpiry(accessToken: String) async {
        guard let context = operationContext() else { return }
        await loadAccessExpiry(accessToken: accessToken, context: context)
    }

    /// Сроки доступа (course_access_expiry, видны только свои строки по RLS).
    /// Ошибка или старая база без таблицы — оставляем как было: сервер всё равно
    /// сам не выдаст видео по истёкшему доступу.
    private func loadAccessExpiry(accessToken: String, context: ProfileOperationContext) async {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/course_access_expiry"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "select", value: "access_key,expires_at")]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([AccessExpiryRow].self, from: data),
              isCurrent(context),
              var current = profile,
              current.id.lowercased() == context.userID
        else { return }
        current.accessExpiry = Dictionary(rows.map { ($0.accessKey, $0.expiresAt) }) { _, last in last }
        profile = current
    }

    private func ensureProfile(userId: String, accessToken: String, context: ProfileOperationContext) async -> Bool {
        guard isCurrent(context) else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/profiles"))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation,resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
        let body: [String: Any] = [
            "id": userId,
            "plan": "free",
            "credits": 0,
            "is_public": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            if isCurrent(context) { error = "Profile creation failed" }
            return false
        }
        guard isCurrent(context) else { return false }

        if let rows = try? JSONDecoder().decode([UserProfile].self, from: data),
           let row = rows.first {
            return commit(row, for: context)
        }

        // With `resolution=ignore-duplicates`, a concurrent trigger or another
        // client can win the insert and PostgREST legitimately returns an empty
        // representation. Resolve that successful race with one bounded GET;
        // never recurse back into profile creation.
        if let row = await refetchProfileAfterIgnoredInsert(
            userId: userId,
            accessToken: accessToken
        ) {
            return commit(row, for: context)
        }
        if isCurrent(context) { error = "Profile refresh returned no data" }
        return false
    }

    private func refetchProfileAfterIgnoredInsert(
        userId: String,
        accessToken: String
    ) async -> UserProfile? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([UserProfile].self, from: data)
        else { return nil }
        return rows.first
    }

    /// Uploads an avatar JPEG to Supabase Storage and patches profiles.avatar to the public URL.
    /// Returns the new URL on success.
    @discardableResult
    func uploadAvatar(_ jpegData: Data, accessToken: String, operation: ProfileOperationContext? = nil) async -> String? {
        guard let context = operation ?? operationContext(), isCurrent(context),
              let userId = profile?.id, userId.lowercased() == context.userID else { return nil }
        let path = "\(userId)/\(Int(Date().timeIntervalSince1970)).jpg"
        let uploadURL = baseURL.appendingPathComponent("storage/v1/object/avatars/\(path)")

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("3600", forHTTPHeaderField: "Cache-Control")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = jpegData

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        guard isCurrent(context) else { return nil }

        let publicURL = baseURL.appendingPathComponent("storage/v1/object/public/avatars/\(path)").absoluteString
        guard await patchMany(["avatar": AnyEncodable(publicURL)], accessToken: accessToken, operation: context) else { return nil }
        return publicURL
    }

    /// Patches a single field on the profile row.
    @discardableResult
    func patch<T: Encodable>(_ field: String, value: T, accessToken: String, operation: ProfileOperationContext? = nil) async -> Bool {
        await patchMany([field: AnyEncodable(value)], accessToken: accessToken, operation: operation)
    }

    /// Patches several fields atomically.
    @discardableResult
    func patchMany(_ fields: [String: AnyEncodable], accessToken: String, operation: ProfileOperationContext? = nil) async -> Bool {
        guard let context = operation ?? operationContext(), isCurrent(context) else { return false }
        guard let id = profile?.id else {
            error = "Profile is not loaded"
            return false
        }
        guard id.lowercased() == context.userID else { return false }
        error = nil
        do {
            var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PATCH"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONEncoder().encode(fields)

            let (data, response) = try await session.data(for: request)
            guard isCurrent(context) else { return false }
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                if let rows = try? JSONDecoder().decode([UserProfile].self, from: data), let row = rows.first {
                    return commit(row, for: context)
                }
                error = "Profile save returned an empty response"
                return false
            }
            if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? ""
                error = body.isEmpty ? "Profile save failed (\(http.statusCode))" : body
            } else {
                error = "Profile save failed"
            }
            return false
        } catch {
            if isCurrent(context) { self.error = error.localizedDescription }
            return false
        }
    }
}

/// Type-erased Encodable wrapper for heterogeneous JSON dicts.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        self._encode = value.encode
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
