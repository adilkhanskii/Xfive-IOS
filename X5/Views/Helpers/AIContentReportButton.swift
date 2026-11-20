import SwiftUI

/// Кнопка «Пожаловаться» под результатом ИИ — как на вебе и Android (#29).
/// Открывает шторку: причина + комментарий → строка в `public.reports` и пуш разработчикам.
struct AIContentReportButton: View {
    let tool: String
    var contentURL: String? = nil
    var contentText: String? = nil
    var prompt: String? = nil
    /// Только иконка — для пузырей чата и тесных мест.
    var compact: Bool = false

    @EnvironmentObject private var loc: LocalizationService
    @State private var showingSheet = false

    var body: some View {
        Button {
            X5Feedback.selection()
            showingSheet = true
        } label: {
            if compact {
                Image(systemName: "flag")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                Label(AIContentReportText.button(loc.current), systemImage: "flag")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AIContentReportText.button(loc.current))
        .accessibilityIdentifier("ai.report.button")
        .sheet(isPresented: $showingSheet) {
            AIContentReportSheet(
                tool: tool,
                contentURL: contentURL,
                contentText: contentText,
                prompt: prompt
            )
        }
    }
}

private struct AIContentReportSheet: View {
    let tool: String
    let contentURL: String?
    let contentText: String?
    let prompt: String?

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case idle, sending, done, failed, signedOut }

    @State private var reason: AIContentReportReason?
    @State private var comment = ""
    @State private var phase: Phase = .idle

    private var lang: AppLanguage { loc.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text(AIContentReportText.title(lang))
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                if phase == .done {
                    doneView
                } else {
                    form
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AIContentReportText.hint(lang))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(AIContentReportReason.allCases) { item in
                    Button {
                        X5Feedback.selection()
                        reason = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: reason == item ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(reason == item ? X5Style.blue : .white.opacity(0.4))
                            Text(AIContentReportText.reason(item, lang))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(reason == item ? 0.1 : 0.05))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ai.report.reason.\(item.rawValue)")
                }
            }

            TextField(AIContentReportText.comment(lang), text: $comment, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .accessibilityIdentifier("ai.report.comment")

            if phase == .failed || phase == .signedOut {
                Text(phase == .signedOut ? AIContentReportText.signIn(lang) : AIContentReportText.error(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 1, green: 0.45, blue: 0.4))
            }

            Button {
                Task { await submit() }
            } label: {
                ZStack {
                    if phase == .sending {
                        ProgressView().tint(.black)
                    } else {
                        Text(AIContentReportText.send(lang))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(.black)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(X5Style.blue.opacity(reason == nil ? 0.35 : 1))
                )
            }
            .buttonStyle(.plain)
            .disabled(reason == nil || phase == .sending)
            .accessibilityIdentifier("ai.report.send")
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(X5Style.blue)
                Text(AIContentReportText.done(lang))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { dismiss() } label: {
                Text("OK")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(X5Style.blue))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ai.report.done")
        }
    }

    private func submit() async {
        guard let reason, phase != .sending else { return }
        phase = .sending
        #if DEBUG
        // Только QA-скрин: без сервера показываем «спасибо».
        if AIReportQAPreview.isOn {
            _ = reason
            phase = .done
            return
        }
        #endif
        guard let userId = auth.userId, let token = await auth.freshAccessToken() else {
            phase = .signedOut
            return
        }
        let report = AIContentReport(
            tool: tool,
            reason: reason,
            comment: comment,
            contentURL: contentURL,
            contentText: contentText,
            prompt: prompt
        )
        let service = AIContentReportService()
        do {
            try await service.send(report, userId: userId, accessToken: token)
            X5Feedback.success()
            phase = .done
            Task { await service.notifyDevelopers(report) }
        } catch {
            X5Feedback.error()
            phase = .failed
        }
    }
}

/// Тексты шторки — те же, что у веба.
enum AIContentReportText {
    static func button(_ lang: AppLanguage) -> String {
        pick(lang, ru: "Пожаловаться", kk: "Шағым", en: "Report")
    }

    static func title(_ lang: AppLanguage) -> String {
        pick(lang, ru: "Пожаловаться на результат ИИ", kk: "ЖИ нәтижесіне шағым", en: "Report AI-generated content")
    }

    static func hint(_ lang: AppLanguage) -> String {
        pick(
            lang,
            ru: "Опишите, что не так. Мы проверим и уберём такой контент.",
            kk: "Не дұрыс емес екенін жазыңыз. Тексеріп, мұндай мазмұнды алып тастаймыз.",
            en: "Tell us what is wrong. We review every report and remove such content."
        )
    }

    static func comment(_ lang: AppLanguage) -> String {
        pick(lang, ru: "Комментарий (необязательно)", kk: "Пікір (міндетті емес)", en: "Comment (optional)")
    }

    static func send(_ lang: AppLanguage) -> String {
        pick(lang, ru: "Отправить жалобу", kk: "Шағымды жіберу", en: "Send report")
    }

    static func done(_ lang: AppLanguage) -> String {
        pick(
            lang,
            ru: "Спасибо, жалоба отправлена. Мы её проверим.",
            kk: "Рақмет, шағым жіберілді. Біз тексереміз.",
            en: "Thank you, your report has been sent. We will review it."
        )
    }

    static func signIn(_ lang: AppLanguage) -> String {
        pick(
            lang,
            ru: "Войдите в аккаунт, чтобы отправить жалобу.",
            kk: "Шағым жіберу үшін аккаунтқа кіріңіз.",
            en: "Please sign in to send a report."
        )
    }

    static func error(_ lang: AppLanguage) -> String {
        pick(
            lang,
            ru: "Не удалось отправить. Попробуйте ещё раз.",
            kk: "Жіберу мүмкін болмады. Қайталап көріңіз.",
            en: "Could not send. Please try again."
        )
    }

    static func reason(_ reason: AIContentReportReason, _ lang: AppLanguage) -> String {
        switch reason {
        case .sexual:
            return pick(lang, ru: "Сексуальный контент", kk: "Жыныстық мазмұн", en: "Sexual content")
        case .violence:
            return pick(lang, ru: "Насилие или опасные действия", kk: "Зорлық немесе қауіпті әрекет", en: "Violence or dangerous acts")
        case .hate:
            return pick(lang, ru: "Оскорбления или ненависть", kk: "Қорлау немесе өшпенділік", en: "Hate or harassment")
        case .deepfake:
            return pick(lang, ru: "Чужое лицо или обман", kk: "Бөтен адамның беті немесе алдау", en: "Real person / deepfake / misleading")
        case .other:
            return pick(lang, ru: "Другое", kk: "Басқа", en: "Other")
        }
    }

    private static func pick(_ lang: AppLanguage, ru: String, kk: String, en: String) -> String {
        switch lang {
        case .ru: return ru
        case .kk: return kk
        case .en: return en
        }
    }
}
