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

    /// Из `application(_:didFinishLaunchingWithOptions:)`.
    /// Событие запуска (fb_mobile_activate_app) SDK пишет сам при каждой
    /// активации — `FacebookAutoLogAppEventsEnabled` = true в Info.plist,
    /// поэтому отдельный `activateApp()` не зовём (иначе запуск задвоится).
    static func start(
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

    /// Системный запрос ATT. Только на главном экране после входа, не на
    /// холодном старте (Apple отклоняет запрос до интерфейса). Один раз:
    /// после ответа система больше не спрашивает.
    @MainActor
    static func requestTrackingAuthorizationIfNeeded() async {
        guard started,
              !UserDefaults.standard.bool(forKey: skipTrackingPromptKey),
              ATTrackingManager.trackingAuthorizationStatus == .notDetermined,
              UIApplication.shared.applicationState == .active
        else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
        syncAdvertiserTracking()
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
