import StoreKit
import SwiftUI

/// One-time credit store. The historical name is kept so existing callers do
/// not need to change while legacy subscriptions remain restorable elsewhere.
struct PaywallView: View {
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @EnvironmentObject private var iap: IAPService
    @Environment(\.dismiss) private var dismiss

    @State private var didLoadProducts = false
    @State private var purchasingProductID: String?
    @State private var purchasedCredits = 0
    @State private var profileReloadSucceeded = true
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "cart.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)

                    Text(loc.t("credit_store_title"))
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)

                    Text(loc.t("credit_store_description"))
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    balanceCard

                    VStack(spacing: 12) {
                        ForEach(IAPProductCatalog.visibleCreditPacks) { pack in
                            packCard(pack)
                        }
                    }

                    Text(loc.t("credit_store_delivery_note"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 18) {
                        if let termsURL = URL(string: "https://tooyakov-art.github.io/x5site/terms.html") {
                            Link(loc.t("credit_store_terms_link"), destination: termsURL)
                        }
                        if let privacyURL = URL(string: "https://tooyakov-art.github.io/x5site/privacy.html") {
                            Link(loc.t("credit_store_privacy_link"), destination: privacyURL)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)

                    if let error = iap.lastError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    if didLoadProducts && (hasMissingCreditPacks || iap.lastError != nil) {
                        Button {
                            Task { await reloadProducts() }
                        } label: {
                            Group {
                                if iap.isLoadingProducts {
                                    ProgressView().tint(.black)
                                } else {
                                    Text(loc.t("btn_retry"))
                                        .font(.system(size: 15, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 24)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .foregroundStyle(.black)
                        .disabled(iap.isLoadingProducts || iap.isPurchasing)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
            .navigationTitle(loc.t("credit_store_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("btn_done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await reloadProducts()
        }
        .alert(loc.t("credit_store_success_title"), isPresented: $showSuccess) {
            Button(loc.t("btn_done")) { dismiss() }
        } message: {
            let messageKey = IAPCreditPurchaseConfirmation.messageKey(
                profileReloadSucceeded: profileReloadSucceeded
            )
            if profileReloadSucceeded {
                Text(String(format: loc.t(messageKey), purchasedCredits))
            } else {
                Text(loc.t(messageKey))
            }
        }
    }

    private var balanceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("credit_store_balance"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text((currentUser.profile?.credits ?? 0).formatted())
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundColor(.white)
            }
            Spacer()
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.12)
    }

    private func packCard(_ pack: IAPCreditPack) -> some View {
        let product = iap.product(id: pack.productID)
        let isCurrentPurchase = purchasingProductID == pack.productID && iap.isPurchasing

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: loc.t("credit_store_pack_credits"), pack.credits))
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundColor(.white)
                    Text(loc.t("credit_store_one_time"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Text(product?.displayPrice ?? pack.fallbackDisplayPrice)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(.accentColor)
            }

            Button {
                X5Feedback.selection()
                buyViaAppStore(pack)
            } label: {
                Group {
                    if isCurrentPurchase {
                        ProgressView().tint(.black)
                    } else {
                        Text(loc.t("credit_store_buy"))
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .foregroundStyle(.black)
            .disabled(iap.isPurchasing)

            if didLoadProducts && product == nil {
                Text(loc.t("credit_store_unavailable"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func buyViaAppStore(_ pack: IAPCreditPack) {
        DiagnosticLogger.log(event: "credit_payment_method_selected", extra: [
            "method": "app_store_storekit",
            "product": pack.productID
        ])

        Task {
            if iap.product(id: pack.productID) == nil {
                await reloadProducts()
            }
            guard iap.product(id: pack.productID) != nil else {
                X5Feedback.error()
                return
            }
            buy(pack)
        }
    }

    private func buy(_ pack: IAPCreditPack) {
        purchasingProductID = pack.productID
        Task {
            defer { purchasingProductID = nil }
            let delivered = await iap.purchase(productID: pack.productID)
            guard delivered else {
                if iap.lastError != nil { X5Feedback.error() }
                return
            }

            profileReloadSucceeded = await refreshProfile()
            purchasedCredits = pack.credits
            X5Feedback.success()
            showSuccess = true
        }
    }

    private var hasMissingCreditPacks: Bool {
        !IAPProductAvailability.missingCreditPackIDs(
            loadedProductIDs: iap.products.keys
        ).isEmpty
    }

    private func reloadProducts() async {
        didLoadProducts = false
        await iap.loadProducts()
        didLoadProducts = true
    }

    private func refreshProfile() async -> Bool {
        guard let userID = auth.userId,
              let accessToken = await auth.freshAccessToken() else {
            return false
        }
        return await currentUser.load(userId: userID, accessToken: accessToken)
    }
}
