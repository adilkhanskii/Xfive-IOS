import SwiftUI

/// Строка «Начислить кредиты» в профиле владельца (Адильхан 02.11), рядом с «Бонус новым».
struct OwnerCreditsRow: View {
    @EnvironmentObject private var loc: LocalizationService
    let onTap: () -> Void

    var body: some View {
        Button(action: {
            X5Feedback.selection()
            onTap()
        }) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(X5Style.blue)
                Text(loc.t("credits_ctl_row"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityIdentifier("profile.ownerCredits.row")
    }
}

/// Шторка: поиск по почте / нику / имени → выбор → сколько → комментарий →
/// «Начислить» → подтверждение. Права проверяет сервер (owner_* → is_x5_developer).
struct OwnerCreditsSheet: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    let search: (_ query: String) async -> Result<[OwnerCreditsUser], OwnerCreditsError>
    let grant: (_ targetId: String, _ amount: Int, _ note: String) async -> Result<Int, OwnerCreditsError>
    let onGranted: (_ user: OwnerCreditsUser, _ amount: Int, _ balance: Int) -> Void

    @State private var query = ""
    @State private var users: [OwnerCreditsUser]?
    @State private var searching = false
    @State private var selected: OwnerCreditsUser?
    @State private var amountText = ""
    @State private var note = ""
    @State private var error: OwnerCreditsError?
    @State private var confirming = false
    @State private var sending = false
    @State private var searchTask: Task<Void, Never>?

    private let errorColor = Color(red: 0.97, green: 0.44, blue: 0.44)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(loc.t("credits_ctl_title"))
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        selectedCard(selected)
                        inputField(loc.t("credits_ctl_amount"), text: Binding(
                            get: { amountText },
                            set: { amountText = String($0.filter(\.isNumber).prefix(6)); error = nil }
                        ), bad: error == .amount, numeric: true, id: "profile.ownerCredits.amount")
                        inputField(loc.t("credits_ctl_note"), text: Binding(
                            get: { note },
                            set: { note = String($0.prefix(OwnerCreditsError.maxNote)) }
                        ), bad: false, numeric: false, id: "profile.ownerCredits.note")
                    } else {
                        searchField
                        resultsList
                    }

                    if let error {
                        Text(loc.t(error.localizationKey))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(errorColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("profile.ownerCredits.error")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)

            if selected != nil {
                Button(action: askConfirm) {
                    ZStack {
                        if sending {
                            ProgressView().tint(.black)
                        } else {
                            Text(loc.t("credits_ctl_submit"))
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundColor(.black)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(X5Style.blue))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityIdentifier("profile.ownerCredits.submit")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .alert(confirmText, isPresented: $confirming) {
            Button(loc.t("credits_ctl_cancel"), role: .cancel) {}
            Button(loc.t("credits_ctl_yes")) { Task { await send() } }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            TextField(loc.t("credits_ctl_search"), text: Binding(
                get: { query },
                set: { value in
                    query = value
                    error = nil
                    scheduleSearch()
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.white)
            .accessibilityIdentifier("profile.ownerCredits.query")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    @ViewBuilder
    private var resultsList: some View {
        if searching {
            ProgressView().tint(.white).frame(maxWidth: .infinity)
        } else if users == nil {
            hint(loc.t("credits_ctl_search_hint"))
        } else if let users, users.isEmpty, error == nil {
            hint(loc.t("credits_ctl_nothing"))
        } else if let users {
            ForEach(users) { user in
                Button {
                    X5Feedback.selection()
                    selected = user
                    error = nil
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.label)
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text([user.nickname?.isEmpty == false ? user.name : nil, user.email].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(balanceText(user.credits))
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(X5Style.blue)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .x5ClearGlass(cornerRadius: 16, highlight: 0.1)
                .accessibilityIdentifier("profile.ownerCredits.user")
            }
        }
    }

    private func selectedCard(_ user: OwnerCreditsUser) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(X5Style.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.label)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text([balanceText(user.credits), user.email].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                selected = nil
                error = nil
            } label: {
                Text(loc.t("credits_ctl_change"))
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(X5Style.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(X5Style.blue.opacity(0.35), lineWidth: 1))
    }

    private func inputField(_ title: String, text: Binding<String>, bad: Bool, numeric: Bool, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
            TextField("", text: text)
                .keyboardType(numeric ? .numberPad : .default)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(bad ? errorColor : Color.white.opacity(0.1), lineWidth: 1)
                )
                .accessibilityIdentifier(id)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.5))
    }

    private func balanceText(_ credits: Int) -> String {
        loc.t("credits_ctl_balance").replacingOccurrences(of: "{n}", with: "\(credits)")
    }

    private var confirmText: String {
        loc.t("credits_ctl_confirm")
            .replacingOccurrences(of: "{n}", with: "\(OwnerCreditsError.number(from: amountText) ?? 0)")
            .replacingOccurrences(of: "{user}", with: selected?.label ?? "")
    }

    /// Поиск с паузой 350 мс; меньше 3 символов — не ищем.
    private func scheduleSearch() {
        searchTask?.cancel()
        let current = query
        guard OwnerCreditsError.canSearch(current) else {
            users = nil
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let result = await search(current)
            guard !Task.isCancelled, current == query else { return }
            searching = false
            switch result {
            case .success(let found):
                users = found
            case .failure(let failure):
                users = []
                error = failure
            }
        }
    }

    private func askConfirm() {
        if let invalid = OwnerCreditsError.validate(amount: OwnerCreditsError.number(from: amountText)) {
            error = invalid
            X5Feedback.error()
            return
        }
        error = nil
        confirming = true
    }

    private func send() async {
        guard !sending, let selected, let amount = OwnerCreditsError.number(from: amountText) else { return }
        sending = true
        error = nil
        let result = await grant(selected.id, amount, note)
        sending = false
        switch result {
        case .success(let balance):
            X5Feedback.success()
            onGranted(selected, amount, balance)
            dismiss()
        case .failure(let failure):
            error = failure
            X5Feedback.error()
        }
    }
}
