import StoreKit
import SwiftUI
import UIKit

/// Sells the blue verified badge as a separate App Store subscription.
struct VerifiedBadgeView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @EnvironmentObject private var iap: IAPService
    @Environment(\.dismiss) private var dismiss

    @State private var showSuccess = false
    @State private var errorText: String?
    @State private var isRestoring = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color.accentColor, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Image(systemName: "checkmark")
                            .font(.system(size: 48, weight: .heavy))
                            .foregroundColor(.white)
                    }
                    .frame(width: 96, height: 96)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)

                    Text(loc.t("verified_title"))
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)

                    Text(loc.t("verified_subtitle"))
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 14) {
                        // Адильхан 10.10: главное — задания первым. Сервер так и делает:
                        // триггер tasks_priority_notify шлёт пуш с галочкой сразу, остальным через час.
                        Benefit(icon: "bell.badge.fill", text: loc.t("verified_benefit_tasks"))
                        Benefit(icon: "arrow.up.circle.fill", text: loc.t("verified_benefit_1"))
                        Benefit(icon: "shield.checkered", text: loc.t("verified_benefit_2"))
                        Benefit(icon: "person.crop.circle.badge.checkmark", text: loc.t("verified_benefit_3"))
                    }
                    .padding(18)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if currentUser.profile?.hasActiveVerifiedBadge == true {
                        activeBlock
                    } else {
                        purchaseBlock
                    }

                    Button {
                        restoreVerifiedSubscription()
                    } label: {
                        if isRestoring {
                            ProgressView()
                        } else {
                            Text(loc.t("verified_restore"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(isRestoring || iap.isPurchasing)

                    Text(String(format: loc.t("verified_subscription_terms"), verifiedDisplayPrice))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 18) {
                        if let termsURL = URL(string: "https://tooyakov-art.github.io/x5site/terms.html") {
                            Link(loc.t("verified_terms_link"), destination: termsURL)
                        }
                        if let privacyURL = URL(string: "https://tooyakov-art.github.io/x5site/privacy.html") {
                            Link(loc.t("verified_privacy_link"), destination: privacyURL)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
            .navigationTitle(loc.t("verified_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("btn_done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await iap.loadProducts() }
        .onChange(of: iap.lastError) { errorText = $0 }
        .alert(loc.t("verified_success_title"), isPresented: $showSuccess) {
            Button(loc.t("btn_done")) { dismiss() }
        } message: {
            Text(loc.t("verified_success_message"))
        }
    }

    private var purchaseBlock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: loc.t("verified_price_period"), verifiedDisplayPrice))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(loc.t("verified_purchase_note"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(14)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                buyVerified()
            } label: {
                VStack(spacing: 4) {
                    if iap.isPurchasing {
                        ProgressView()
                    } else {
                        Text(String(format: loc.t("verified_buy_button"), verifiedDisplayPrice))
                            .font(.system(size: 16, weight: .bold))
                    }
                    Text(loc.t("verified_cancel_note"))
                        .font(.system(size: 11))
                        .opacity(0.72)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(verifiedProduct == nil || iap.isPurchasing)

            if verifiedProduct == nil && iap.lastError == nil {
                Text(loc.t("verified_unavailable"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var activeBlock: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundColor(.accentColor)
            Text(loc.t("verified_active") + " " + formatDate(currentUser.profile?.verifiedUntil))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            if iap.activeSubscriptionSnapshot.hasActiveVerifiedSubscription {
                Button(loc.t("verified_manage")) {
                    openSubscriptionManagement()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var verifiedProduct: Product? {
        iap.product(id: IAPService.verifiedMonthlyProductID)
    }

    private var verifiedDisplayPrice: String {
        verifiedProduct?.displayPrice ?? IAPService.verifiedDisplayPrice
    }

    private func buyVerified() {
        errorText = nil
        Task {
            let delivered = await iap.purchase(productID: IAPService.verifiedMonthlyProductID)
            guard delivered else {
                // StoreKit cancellation is an ordinary choice, not a failure.
                // Pending and server errors already provide a specific message.
                errorText = iap.lastError
                if errorText != nil { X5Feedback.error() }
                return
            }
            await refreshProfile()
            X5Feedback.success()
            showSuccess = true
        }
    }

    private func restoreVerifiedSubscription() {
        errorText = nil
        isRestoring = true
        Task {
            defer { isRestoring = false }
            await iap.restore()
            await refreshProfile()
            errorText = iap.lastError
        }
    }

    private func refreshProfile() async {
        if let userID = auth.userId,
           let accessToken = await auth.freshAccessToken() {
            await currentUser.load(userId: userID, accessToken: accessToken)
        }
    }

    private func openSubscriptionManagement() {
        guard let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    private func formatDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let output = DateFormatter()
        output.locale = Locale(identifier: loc.current.rawValue)
        output.dateStyle = .medium
        return output.string(from: date)
    }
}

private struct Benefit: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
    }
}

/// Small verified chip rendered next to a name when the subscription is active.
struct VerifiedChip: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(.accentColor)
    }
}
