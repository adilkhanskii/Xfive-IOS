import AppTrackingTransparency
import FacebookCore
import Foundation
import StoreKit
import UIKit

/// Meta (Facebook) SDK: установка, запуск, регистрация и покупки для рекламы
/// X5 в Meta на iOS 14+ (AEM + SKAdNetwork).
/// Зачем (Адильхан 02.11): Ads Manager давал только «iOS 13.7 и старее» —
/// в приложении не было SDK, Events Manager не видел ни одного события.
///
/// App ID и Client Token приходят из сборки (`FACEBOOK_APP_ID` /
/// `FACEBOOK_CLIENT_TOKEN` → Info.plist). Пока их нет — SDK не запускается
/// вовсе, приложение работает как раньше.
/// Личные данные (почта, имя, телефон) в Meta не уходят — только события.
enum MetaAnalytics {
    /// Пропуск системного запроса трекинга в UI-тестах (иначе алерт закроет экран).
    static let skipTrackingPromptKey = "x5.skipTrackingPrompt"

    private static var started = false

    /// Числовой App ID из Info.plist; пусто/не число → SDK выключен.
    static func configuredAppID(in info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let raw = info?["FacebookAppID"] as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        guard let token = info?["FacebookClientToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.hasPrefix("$(") else { return nil }
        return id
    }

    static var isConfigured: Bool { configuredAppID() != nil }

    private static var pendingLaunchOptions: [UIApplication.LaunchOptionsKey: Any]?
    private static var trackingResolved = false
    private static var trackingWaiters: [CheckedContinuation<Void, Never>] = []

    /// Из `application(_:didFinishLaunchingWithOptions:)`.
    /// Отказ Apple 5.1.2(i) 04.11 (1.1.21/271): проверяющий не увидел окно ATT —
    /// оно спрашивалось только после входа и одновременно с запросом пушей
    /// (iOS не показывает ATT поверх другого системного окна), а SDK стартовал
    /// ещё до ответа. Теперь: ответ на ATT уже есть → SDK сразу; нет ответа →
    /// SDK ждёт окна ATT на первом экране (requestTrackingOnLaunch).
    /// Событие запуска (fb_mobile_activate_app) SDK пишет сам —
    /// `FacebookAutoLogAppEventsEnabled` = true, отдельный `activateApp()` не зовём.
    static func start(
        _ application: UIApplication,
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        guard isConfigured, !started else { return }
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined,
           !UserDefaults.standard.bool(forKey: skipTrackingPromptKey) {
            pendingLaunchOptions = launchOptions
            return
        }
        resolveTracking()
        startSDK(application, launchOptions: launchOptions)
    }

    private static func startSDK(
        _ application: UIApplication,
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        guard isConfigured, !started else { return }
        started = true
        ApplicationDelegate.shared.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
        syncAdvertiserTracking()
    }

    /// Ссылки из рекламы (AEM передаёт параметры клика через URL).
    static func handle(_ url: URL) {
        guard started else { return }
        ApplicationDelegate.shared.application(
            UIApplication.shared,
            open: url,
            options: [:]
        )
    }

    /// Системный запрос ATT — при первом запуске, на первом экране (до входа),
    /// раньше запроса пушей и до старта Meta SDK. Ждём, пока приложение
    /// станет активным (Face ID / системные окна делают его неактивным —
    /// тогда iOS молча не показывает ATT). Один раз: после ответа система
    /// больше не спрашивает.
    @MainActor
    static func requestTrackingOnLaunch() async {
        defer { resolveTracking() }
        guard isConfigured,
              !UserDefaults.standard.bool(forKey: skipTrackingPromptKey)
        else { return }
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            // Первый кадр интерфейса уже на экране — запрос не на «пустом» старте.
            try? await Task.sleep(nanoseconds: 800_000_000)
            for _ in 0..<40 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                _ = await ATTrackingManager.requestTrackingAuthorization()
            }
        }
        startSDK(UIApplication.shared, launchOptions: pendingLaunchOptions)
        pendingLaunchOptions = nil
    }

    /// Запрос пушей ждёт ответа на ATT, чтобы два системных окна не налезли
    /// друг на друга (иначе iOS не покажет ATT).
    @MainActor
    static func waitForTrackingPrompt() async {
        guard isConfigured, !trackingResolved else { return }
        await withCheckedContinuation { trackingWaiters.append($0) }
    }

    private static func resolveTracking() {
        guard !trackingResolved else { return }
        trackingResolved = true
        let waiters = trackingWaiters
        trackingWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// iOS 16: SDK берёт флаг отсюда; на iOS 17+ сам читает статус ATT.
    private static func syncAdvertiserTracking() {
        if #unavailable(iOS 17) {
            Settings.shared.isAdvertiserTrackingEnabled =
                ATTrackingManager.trackingAuthorizationStatus == .authorized
        }
    }

    /// Регистрация = первая успешно сохранённая анкета (вход через Apple/Google
    /// тоже создаёт аккаунт, поэтому не привязываемся к форме почты).
    static func logCompletedRegistration() {
        guard started else { return }
        AppEvents.shared.logEvent(.completedRegistration)
    }

    /// Успешная покупка StoreKit (кредиты или подписка). Сумма и валюта — из
    /// карточки товара App Store. transaction_id/content_id — чтобы Meta
    /// склеила это событие с автоматическим логом покупок SDK и не задвоила.
    static func logPurchase(product: Product, transactionID: UInt64, isSubscription: Bool) {
        guard started else { return }
        let amount = NSDecimalNumber(decimal: product.price).doubleValue
        let currency = product.priceFormatStyle.currencyCode
        let parameters: [AppEvents.ParameterName: Any] = [
            .contentID: product.id,
            .contentType: isSubscription ? "subscription" : "credits",
            .currency: currency,
            .transactionID: String(transactionID),
        ]
        if isSubscription {
            AppEvents.shared.logEvent(.subscribe, valueToSum: amount, parameters: parameters)
        } else {
            AppEvents.shared.logPurchase(amount: amount, currency: currency, parameters: parameters)
        }
    }
}
