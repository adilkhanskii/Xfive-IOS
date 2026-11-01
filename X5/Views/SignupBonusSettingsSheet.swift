import SwiftUI

/// Строка «Бонус новым» в профиле владельца (Адильхан 01.11):
/// «выдано N из L · C кредитов» + «включён» / «на паузе». Тап открывает настройки.
struct SignupBonusOwnerRow: View {
    @EnvironmentObject private var loc: LocalizationService
    let stats: SignupBonusStats
    let onTap: () -> Void

    var body: some View {
        Button(action: {
            X5Feedback.selection()
            onTap()
        }) {
            HStack(spacing: 10) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(stats.enabled ? X5Style.blue : .white.opacity(0.5))
                Text(
                    loc.t("bonus_ctl_row")
                        .replacingOccurrences(of: "{n}", with: "\(stats.granted)")
                        .replacingOccurrences(of: "{max}", with: "\(stats.maxGrants)")
                        .replacingOccurrences(of: "{credits}", with: "\(stats.credits)")
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                Text(loc.t(stats.enabled ? "bonus_ctl_on" : "bonus_ctl_paused"))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(stats.enabled ? X5Style.blue : .white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(stats.enabled ? X5Style.blue.opacity(0.14) : Color.white.opacity(0.08))
                    )
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .x5ClearGlass(cornerRadius: 16, highlight: 0.12)
        .accessibilityIdentifier("profile.signupBonus.row")
    }
}

/// Шторка: «Раздавать бонус», «Сколько кредитов дарить», «Скольким новым (лимит)», «Сохранить».
/// Права проверяет сервер (signup_bonus_update_settings → is_x5_developer).
struct SignupBonusSettingsSheet: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    let stats: SignupBonusStats
    let save: (_ enabled: Bool, _ credits: Int, _ maxGrants: Int) async -> Result<SignupBonusStats, SignupBonusSettingsError>
    let onSaved: (SignupBonusStats) -> Void

    @State private var enabled: Bool
    @State private var creditsText: String
    @State private var limitText: String
    @State private var error: SignupBonusSettingsError?
    @State private var saving = false

    init(
        stats: SignupBonusStats,
        save: @escaping (_ enabled: Bool, _ credits: Int, _ maxGrants: Int) async -> Result<SignupBonusStats, SignupBonusSettingsError>,
        onSaved: @escaping (SignupBonusStats) -> Void
    ) {
        self.stats = stats
        self.save = save
        self.onSaved = onSaved
        _enabled = State(initialValue: stats.enabled)
        _creditsText = State(initialValue: "\(stats.credits)")
        _limitText = State(initialValue: "\(stats.maxGrants)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(loc.t("bonus_ctl_title"))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("bonus_ctl_toggle"))
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(.white)
                    Text(loc.t("bonus_ctl_toggle_hint"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color.accentColor)
                    .accessibilityIdentifier("profile.signupBonus.toggle")
                    .onChange(of: enabled) { _ in
                        X5Feedback.selection()
                        error = nil
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .x5ClearGlass(cornerRadius: 18, highlight: 0.12)

            numberField(loc.t("bonus_ctl_credits"), text: $creditsText, bad: error == .credits, id: "profile.signupBonus.credits")
            numberField(loc.t("bonus_ctl_limit"), text: $limitText, bad: error == .limit, id: "profile.signupBonus.limit")

            Text(loc.t("bonus_ctl_granted").replacingOccurrences(of: "{n}", with: "\(stats.granted)"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            if let error {
                Text(errorText(error))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.97, green: 0.44, blue: 0.44))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.signupBonus.error")
            }

            Button {
                Task { await submit() }
            } label: {
                ZStack {
                    if saving {
                        ProgressView().tint(.black)
                    } else {
                        Text(loc.t("btn_save"))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(.black)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(X5Style.blue))
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityIdentifier("profile.signupBonus.save")

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func numberField(_ title: String, text: Binding<String>, bad: Bool, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
            TextField("", text: Binding(
                get: { text.wrappedValue },
                set: { value in
                    text.wrappedValue = String(value.filter(\.isNumber).prefix(7))
                    error = nil
                }
            ))
            .keyboardType(.numberPad)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(bad ? Color(red: 0.97, green: 0.44, blue: 0.44) : Color.white.opacity(0.1), lineWidth: 1)
            )
            .accessibilityIdentifier(id)
        }
    }

    private func errorText(_ error: SignupBonusSettingsError) -> String {
        loc.t(error.localizationKey).replacingOccurrences(of: "{n}", with: "\(stats.granted)")
    }

    private func submit() async {
        guard !saving else { return }
        let credits = SignupBonusSettingsError.number(from: creditsText)
        let limit = SignupBonusSettingsError.number(from: limitText)
        if let invalid = SignupBonusSettingsError.validate(credits: credits, maxGrants: limit, granted: stats.granted) {
            error = invalid
            X5Feedback.error()
            return
        }
        guard let credits, let limit else { return }
        saving = true
        error = nil
        let result = await save(enabled, credits, limit)
        saving = false
        switch result {
        case .success(let next):
            X5Feedback.success()
            onSaved(next)
            dismiss()
        case .failure(let failure):
            error = failure
            X5Feedback.error()
        }
    }
}
