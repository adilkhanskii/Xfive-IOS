import SwiftUI
import GoogleSignIn

@main
struct X5App: App {
    @UIApplicationDelegateAdaptor(X5AppDelegate.self) private var appDelegate

    // Build 67: baseline kept — these services don't have `static let shared`
    // in 56/61 codebase (that was a build 63 nuclear refactor we rolled back).
    // The `@StateObject = NewInstance()` pattern is fine since ContentView /
    // HomeView read these via @EnvironmentObject, not via `.shared`.
    @StateObject private var auth: Auth
    @StateObject private var history = CaptionHistory()
    @StateObject private var brand = BrandProfile()
    @StateObject private var subscription = Subscription()
    @StateObject private var currentUser = CurrentUser()
    @StateObject private var localization = LocalizationService.shared
    @StateObject private var iap: IAPService

    @Environment(\.scenePhase) private var scenePhase
    /// Было ли приложение именно в фоне (а не просто «неактивно»).
    /// Зачем (Адильхан 10.10, видео: галерея мигает, снова просит Face ID, фото не выбирается):
    /// системная галерея и запрос Face ID делают приложение «неактивным» на секунду.
    /// Раньше каждое возвращение в «активно» перезагружало профиль и покупки —
    /// весь экран перерисовывался, галерея перезапускалась, и так по кругу.
    /// Теперь обновляемся только после настоящего ухода в фон.
    @State private var returnedFromBackground = false

    init() {
        // Build 67: install crash + lifecycle reporter BEFORE any other init.
        // Sends device info + uncaught exception traces to Supabase
        // `app_diagnostics`. We need this because TestFlight's automatic
        // crash channel is empty for our recent builds (Apple's
        // diagnosticSignatures endpoint returns 404), so we can't tell what
        // is crashing. Self-collected traces fill the gap.
        DiagnosticLogger.bootstrap()

        let auth = Auth()
        _auth = StateObject(wrappedValue: auth)
        _iap = StateObject(wrappedValue: IAPService(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .environmentObject(auth)
                .environmentObject(history)
                .environmentObject(brand)
                .environmentObject(subscription)
                .environmentObject(currentUser)
                .environmentObject(localization)
                .environmentObject(iap)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Forward custom-scheme callbacks to the Google Sign-In SDK.
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task(id: auth.isAuthenticated) {
                    DiagnosticLogger.log(event: "auth_state",
                                         extra: ["authenticated": auth.isAuthenticated ? "true" : "false"])
                    syncPushRegistrationIfNeeded()
                    await syncStoreKitAndProfile(source: "auth")
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background { returnedFromBackground = true }
                    guard phase == .active, returnedFromBackground else { return }
                    returnedFromBackground = false
                    syncPushRegistrationIfNeeded()
                    // `UserProfile.isPro` evaluates the server expiration against
                    // the current time. Re-evaluate the cached profile every time
                    // the app becomes active so an expired plan cannot remain Pro.
                    subscription.sync(from: currentUser.profile)
                    Task { await syncStoreKitAndProfile(source: "active") }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .x5DidUpdateStoreEntitlements)
                ) { note in
                    guard let userID = note.object as? String else { return }
                    Task { await refreshProfileAfterStoreDelivery(userID: userID) }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .x5DidReconcileStoreRefund
                    )
                ) { _ in
                    Task { await syncStoreKitAndProfile(source: "store_refund") }
                }
        }
    }

    @ViewBuilder
    private var appRoot: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["X5_HOME_QA_PREVIEW"] == "1" {
            AppTabView()
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    private func syncPushRegistrationIfNeeded() {
        if auth.isAuthenticated {
            PushNotifications.shared.bootstrap()
            PushNotifications.shared.currentUserDidChange(
                userId: auth.userId,
                accessToken: auth.accessToken,
                freshAccessTokenProvider: { [weak auth] in
                    await auth?.freshAccessToken(
                        invalidateSessionOnCredentialFailure: false
                    )
                }
            )
        } else {
            PushNotifications.shared.cancelPromoLoop()
        }
    }

    private func refreshProfileAfterStoreDelivery(userID: String) async {
        // A delivery event must not trigger another StoreKit replay. That would
        // create a feedback loop with current entitlements and duplicate events.
        guard auth.isAuthenticated, auth.userId == userID,
              let accessToken = await auth.freshAccessToken(),
              auth.userId == userID else { return }
        await currentUser.load(userId: userID, accessToken: accessToken)
        guard auth.userId == userID else { return }
        subscription.sync(from: currentUser.profile)
    }

    private func syncStoreKitAndProfile(source: String) async {
        guard auth.isAuthenticated else { return }
        await iap.syncRevokedStoreTransactions(source: "\(source)_revoked")
        await iap.retryUnfinishedConsumables(source: "\(source)_unfinished")
        await iap.syncCurrentEntitlements(source: source)

        if let userId = auth.userId,
           let accessToken = await auth.freshAccessToken() {
            await currentUser.load(userId: userId, accessToken: accessToken)
        }
        subscription.sync(from: currentUser.profile)
    }
}
