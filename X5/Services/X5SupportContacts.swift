import Foundation

/// Контакты поддержки (Адильхан 22.10: «чтоб выходил мой WhatsApp и основной аккаунт X5»).
/// Основной аккаунт X5 = владелец в public.executive_admins (role=owner) — Adilkhan, @adilkhan_marketing.
/// Те же значения на сайте: web/src/config/supportContacts.ts.
enum X5SupportContacts {
    static let whatsappPhone = "77007744401"
    static let whatsappURL = "https://wa.me/\(whatsappPhone)"
    static let officialAccountId = "eee55a08-18d1-46e3-a303-1411d1bb9333"
    /// Почта поддержки = та же, что на сайте (Настройки → Поддержка).
    /// Было support@x5studio.app — у домена нет MX-записи, письма не доходили (23.10).
    static let email = "adilkhanskii@gmail.com"
    static var mailtoURL: URL? {
        let subject = "Xfive marketing — вопрос".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(email)?subject=\(subject)")
    }

    /// Сам владелец (Адильхан) не может написать себе — ему открываем вкладку «Чаты»,
    /// куда приходят сообщения поддержки.
    static func isOfficialAccount(_ userId: String?) -> Bool {
        guard let userId else { return false }
        return userId.caseInsensitiveCompare(officialAccountId) == .orderedSame
    }
}
