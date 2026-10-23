import Foundation
import UIKit
import UserNotifications

/// Manages APNs registration through the canonical atomic Edge endpoint.
@MainActor
final class PushNotifications: NSObject, ObservableObject {
    static let shared = PushNotifications()

    private let baseURL: URL
    private let anonKey: String
    private let urlSession: URLSession

    override convenience init() {
        self.init(
            baseURL: URL(string: "https://afwznqjpshybmqhlewmy.supabase.co")!,
            anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmd3pucWpwc2h5Ym1xaGxld215Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzNTUxMTcsImV4cCI6MjA4NTkzMTExN30.p51iPiMEUSETS9Ot_qkmtA3IcqA23kadgoBLLQDXuL0",
            urlSession: .shared
        )
    }

    init(baseURL: URL, anonKey: String, urlSession: URLSession) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.urlSession = urlSession
        super.init()
        // Seed promo toggle to ON for first launch — @AppStorage default in
        // SettingsView only affects UI binding, the underlying UserDefaults
        // key stays nil until the user toggles. Without this seed,
        // schedulePromoLoop() would silently bail on first launch.
        if UserDefaults.standard.object(forKey: Self.promoEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.promoEnabledKey)
        }
    }

    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var deviceToken: String?

    /// Last user we synced the token for. Re-sync when this changes.
    private var lastSyncedUserId: String?
    private var lastSyncedDeviceToken: String?
    private var currentUserId: String?
    private var currentAccessToken: String?
    private var freshAccessTokenProvider: (() async -> String?)?
    private var syncTask: Task<Void, Never>?
    private var syncRevision = 0
    private var registrationEnabled = false

    /// Call after sign-in. Asks permission and registers with APNs.
    func bootstrap() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                self.permissionGranted = granted
                if granted {
                    await MainActor.run {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            } catch {
                self.permissionGranted = false
            }
        }
    }

    func didRegister(deviceToken data: Data) {
        updateDeviceToken(data)
        Task { await syncToken() }
    }

    /// Kept separate from the delegate callback so token persistence can be
    /// exercised deterministically without scheduling a second sync task.
    func updateDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        syncRevision &+= 1
    }

    func didFailToRegister(error: Error) {
        // No-op: surface to UI later if needed
    }

    // MARK: - Promo notifications
    //
    // Local marketing nudges every 5 minutes — never travel through APNs.
    // iOS allows at most 64 pending local notifications, so we schedule a
    // rolling batch covering the next ~hour and refresh on each foreground.

    /// Identifier prefix so we can wipe just our promo notifications without
    /// touching anything else.
    private static let promoIDPrefix = "x5.promo."

    /// Toggle key in UserDefaults — UI flips it via @AppStorage.
    static let promoEnabledKey = "x5.promo.enabled"

    /// Localized headlines + bodies. Cycle through on each scheduled slot.
    /// Tone: friendly, action-oriented, never aggressive.
    private static let promoMessages: [(title: String, body: String)] = [
        ("X Five ✨", "Закинь новый кадр в портфолио — пусть видят твой стиль."),
        ("Hub 🔥", "В Hub появились задания. Лови, пока не разобрали."),
        ("Курсы 🎓", "Новые уроки вышли — прокачай навыки."),
        ("Сторис ✦", "Добавь сторис чтоб подписчики не забыли тебя."),
        ("Чаты 💬", "Кто-то ищет тебя для проекта. Глянь сообщения."),
        ("Профиль 🌟", "Подкрути аватар — на яркие профили кликают чаще."),
        ("Pro 🚀", "Pro даёт безлимит на всё. Посмотри что внутри."),
        ("X Five ✨", "Покажи новую работу — лента ждёт.")
    ]

    /// Schedule a rolling batch of 12 future promos, one every 5 minutes.
    /// Idempotent: cancels any pending promos first.
    func schedulePromoLoop() {
        guard UserDefaults.standard.bool(forKey: Self.promoEnabledKey) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                  || settings.authorizationStatus == .provisional else { return }

            cancelPromoLoop()

            // 12 slots × 5 min = 60 min ahead. App refreshes the queue on
            // each foreground so the user always has an hour scheduled.
            let interval: TimeInterval = 5 * 60
            for slot in 1...12 {
                let copy = Self.promoMessages[(slot - 1) % Self.promoMessages.count]
                let content = UNMutableNotificationContent()
                content.title = copy.title
                content.body = copy.body
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: interval * TimeInterval(slot),
                    repeats: false
                )
                let id = "\(Self.promoIDPrefix)\(slot)"
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    /// Removes all pending promo notifications. Call on sign-out or when the
    /// user disables the toggle. Uses the iOS 16 async API so the closure
    /// stays inside the @MainActor isolation contract instead of jumping to
    /// an arbitrary completion-handler queue.
    func cancelPromoLoop() {
        Task {
            let center = UNUserNotificationCenter.current()
            let requests = await center.pendingNotificationRequests()
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.promoIDPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func currentUserDidChange(
        userId: String?,
        accessToken: String?,
        freshAccessTokenProvider: (() async -> String?)? = nil
    ) {
        guard let userId, let accessToken, !userId.isEmpty, !accessToken.isEmpty else {
            registrationEnabled = false
            currentUserId = nil
            currentAccessToken = nil
            self.freshAccessTokenProvider = nil
            lastSyncedUserId = nil
            lastSyncedDeviceToken = nil
            syncRevision &+= 1
            return
        }
        currentUserId = userId
        currentAccessToken = accessToken
        self.freshAccessTokenProvider = freshAccessTokenProvider
        registrationEnabled = true
        syncRevision &+= 1
        Task { await syncToken() }
    }

    /// Removes only this device's exact APNs tuple before local credentials
    /// are cleared. The Edge Function is the only write path so registration
    /// and legacy profile mirror cleanup remain one atomic server transaction.
    @discardableResult
    func unregisterCurrentDevice(userId: String, accessToken: String) async -> Bool {
        let token = deviceToken ?? lastSyncedDeviceToken
        guard !userId.isEmpty,
              !accessToken.isEmpty,
              let token,
              !token.isEmpty
        else {
            clearLocalRegistrationState()
            return true
        }

        // Stop new registration attempts, then let any already-started exact
        // upsert finish before deleting it. The push token provider never
        // signs out recursively, so this wait cannot await its own task.
        registrationEnabled = false
        syncRevision &+= 1
        if let syncTask {
            await syncTask.value
        }

        var functionRequest = URLRequest(
            url: baseURL.appendingPathComponent("functions/v1/register-push-token")
        )
        functionRequest.httpMethod = "DELETE"
        functionRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        functionRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        functionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        functionRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "platform": "ios"
        ])

        if let (_, response) = try? await urlSession.data(for: functionRequest),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            clearLocalRegistrationState()
            return true
        }

        return false
    }

    /// Local privacy fallback when the server cannot be reached during
    /// logout. A later sign-in calls bootstrap() and obtains/registers a fresh
    /// APNs token for the new account.
    func disableRemoteNotificationsAfterFailedUnregister() {
        UIApplication.shared.unregisterForRemoteNotifications()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        clearLocalRegistrationState()
    }

    private func clearLocalRegistrationState() {
        currentUserId = nil
        currentAccessToken = nil
        freshAccessTokenProvider = nil
        lastSyncedUserId = nil
        lastSyncedDeviceToken = nil
        deviceToken = nil
        registrationEnabled = false
        syncRevision &+= 1
    }

    /// Registers the current device token for the current authenticated user.
    func syncToken() async {
        if let syncTask {
            await syncTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var processedRevision = -1
            repeat {
                let revision = self.syncRevision
                await self.performSyncToken()
                processedRevision = revision
            } while processedRevision != self.syncRevision
            // Clear before completing the task. A token/user update arriving
            // afterwards will create a new drain instead of joining a finished
            // task and losing its sync request.
            self.syncTask = nil
        }
        syncTask = task
        await task.value
    }

    private func performSyncToken() async {
        guard registrationEnabled, let token = deviceToken else { return }
        let userId = currentUserId ?? UserDefaults.standard.string(forKey: "x5.session.user_id")
        let accessToken: String?
        if let freshAccessTokenProvider {
            accessToken = await freshAccessTokenProvider()
        } else {
            accessToken = currentAccessToken ?? Keychain.string(for: "x5.session.access_token")
        }
        guard let userId, let accessToken, !userId.isEmpty, !accessToken.isEmpty else { return }
        currentAccessToken = accessToken
        guard lastSyncedUserId != userId || lastSyncedDeviceToken != token else { return }

        guard await registerTokenViaFunction(token: token, accessToken: accessToken) else { return }
        guard registrationEnabled else { return }
        lastSyncedUserId = userId
        lastSyncedDeviceToken = token
    }

    /// The Edge Function validates the user's JWT and atomically reassigns the
    /// provider token plus its legacy profile mirror with service permissions.
    private func registerTokenViaFunction(token: String, accessToken: String) async -> Bool {
        let url = baseURL.appendingPathComponent("functions/v1/register-push-token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "platform": "ios"
        ])
        guard let (_, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return false }
        return true
    }

}

// MARK: - AppDelegate adapter (handles APNs callbacks)

/// Keeps the application portrait-only except while the dedicated lesson-video
/// cover is on screen. The scene geometry request makes the transition work on
/// iOS 16+ without relying on the private `UIDevice.setValue` rotation hack.
enum AppOrientationCoordinator {
    private(set) static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    static func enterVideoFullscreen() {
        supportedOrientations = .landscape
        requestGeometryUpdate(orientations: .landscape)
    }

    static func leaveVideoFullscreen() {
        supportedOrientations = .portrait
        requestGeometryUpdate(orientations: .portrait)
    }

    private static func requestGeometryUpdate(orientations: UIInterfaceOrientationMask) {
        DispatchQueue.main.async {
            guard Self.supportedOrientations == orientations,
                  let windowScene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
            else { return }

            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in
                // A scene can reject rotation while another system transition
                // is running. The delegate mask remains authoritative for the
                // next orientation update, so no private fallback is needed.
            }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

final class X5AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { @MainActor in AppDeepLinkRouter.shared.route(userInfo: payload) }
        }
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientationCoordinator.supportedOrientations
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotifications.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotifications.shared.didFailToRegister(error: error)
        }
    }

    /// Show banner + sound when a notification arrives while the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = response.notification.request.content.userInfo
        Task { @MainActor in
            AppDeepLinkRouter.shared.route(userInfo: payload)
        }
        // A busy main actor must not delay the system notification callback.
        completionHandler()
    }
}
