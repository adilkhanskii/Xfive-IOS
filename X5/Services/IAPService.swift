import Foundation
import StoreKit

enum IAPEntitlementDisposition: Equatable {
    case applied
    case skipped
    case failed

    var shouldFinishTransaction: Bool {
        switch self {
        case .applied, .skipped: return true
        case .failed: return false
        }
    }

    var isPurchaseSuccess: Bool {
        self == .applied
    }
}

struct IAPTransactionDeliveryKey: Hashable {
    let transactionID: UInt64
    let authenticatedUserID: String?
    let revocationDate: Date?
}

/// Coalesces every StoreKit delivery path for the lifetime of the service.
/// A server failure remains retryable, while a delivered transaction is never
/// verified or finished twice if `purchase`, `updates`, and `unfinished`
/// surface the same transaction for the same X5 account during one app session.
@MainActor
final class IAPTransactionLifecycleCoordinator {
    private var inFlight: [IAPTransactionDeliveryKey: Task<IAPEntitlementDisposition, Never>] = [:]
    private var completed: [IAPTransactionDeliveryKey: IAPEntitlementDisposition] = [:]

    func deliver(
        transactionID: UInt64,
        authenticatedUserID: String?,
        revocationDate: Date? = nil,
        verifyDelivery: @escaping @MainActor () async -> IAPEntitlementDisposition,
        finish: @escaping @MainActor () async -> Void,
        didApply: @escaping @MainActor () -> Void = {}
    ) async -> IAPEntitlementDisposition {
        let deliveryKey = IAPTransactionDeliveryKey(
            transactionID: transactionID,
            authenticatedUserID: authenticatedUserID,
            revocationDate: revocationDate
        )

        if let completedDisposition = completed[deliveryKey] {
            return completedDisposition
        }

        if let existingDelivery = inFlight[deliveryKey] {
            return await existingDelivery.value
        }

        let delivery = Task { @MainActor in
            await verifyDelivery()
        }
        inFlight[deliveryKey] = delivery
        let disposition = await delivery.value
        inFlight[deliveryKey] = nil

        guard disposition.shouldFinishTransaction else {
            return disposition
        }

        // Only a successfully delivered entitlement is safe to cache across
        // calls. `.skipped` may mean a different X5 account owns a restorable
        // subscription, so it must remain eligible for a later account retry.
        if disposition == .applied {
            // Store completion before the suspension point so a duplicate
            // listener event for this account cannot enter a second finish
            // while this one awaits. Another signed-in account must still ask
            // the server to resolve ownership for the same StoreKit transaction.
            completed[deliveryKey] = disposition
        }
        await finish()
        if disposition == .applied { didApply() }
        return disposition
    }
}

enum IAPCreditPurchaseConfirmation {
    static func matchesSelectedProduct(selected: String, returned: String) -> Bool {
        selected == returned
    }

    static func messageKey(profileReloadSucceeded: Bool) -> String {
        profileReloadSucceeded
            ? "credit_store_success_message"
            : "credit_store_success_refresh_pending"
    }
}

enum IAPVerificationRetryPolicy {
    static func shouldRetry(statusCode: Int, retryCount: Int) -> Bool {
        statusCode == 401 && retryCount == 0
    }
}

/// Keeps repeatable consumable purchases stateless. Every tap first asks
/// StoreKit to replay pending delivery; a new charge starts only when that
/// recovery is complete. No product id or date is cached locally.
enum IAPRepeatPurchaseCoordinator {
    @MainActor
    static func perform<PurchaseResult>(
        recoverUnfinished: () async -> Bool,
        startPurchase: () async throws -> PurchaseResult
    ) async rethrows -> PurchaseResult? {
        guard await recoverUnfinished() else {
            return nil
        }
        return try await startPurchase()
    }
}

enum IAPPrePurchaseRecoveryPolicy {
    static func shouldRequireDelivery(
        productID: String,
        transactionAppAccountToken: UUID?,
        currentUserToken: UUID
    ) -> Bool {
        guard transactionAppAccountToken == currentUserToken else {
            return false
        }
        if case .creditPack = IAPProductCatalog.kind(for: productID) {
            return true
        }
        return false
    }
}

enum IAPOwnershipRoutingPolicy {
    /// Apple JWS ownership is decided only by the server. A non-nil token that
    /// differs from the current user can be either another account or one of
    /// the exact legacy chains in the private server allowlist; the client
    /// cannot distinguish those cases safely.
    static func shouldVerifyOnServer(
        signedInUserID: String?,
        transactionAppAccountToken: UUID?
    ) -> Bool {
        _ = transactionAppAccountToken
        guard let signedInUserID else { return false }
        return UUID(uuidString: signedInUserID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
}

struct IAPCreditPack: Identifiable, Equatable, Sendable {
    let productID: String
    let credits: Int
    let fallbackDisplayPrice: String

    var id: String { productID }
}

enum IAPProductKind: Equatable, Sendable {
    case creditPack(IAPCreditPack)
    case legacySubscription
    case verificationSubscription
    case unknown

    var activatesLegacyPro: Bool {
        self == .legacySubscription
    }
}

enum IAPProductCatalog {
    static let liteMonthlyProductID = "com.x5studio.app.lite.monthly"
    static let proMonthlyProductID = "com.x5studio.app.pro.monthly"
    static let maxMonthlyProductID = "com.x5studio.app.max.monthly"
    static let verifiedMonthlyProductID = "com.x5studio.app.verified.monthly"

    static let visibleCreditPacks = [
        IAPCreditPack(
            productID: "com.x5studio.app.credits.1000",
            credits: 1_000,
            fallbackDisplayPrice: "1000 ₸"
        ),
        IAPCreditPack(
            productID: "com.x5studio.app.credits.2000",
            credits: 2_000,
            fallbackDisplayPrice: "2000 ₸"
        ),
        IAPCreditPack(
            productID: "com.x5studio.app.credits.5000",
            credits: 5_000,
            fallbackDisplayPrice: "5000 ₸"
        )
    ]

    static let legacySubscriptionProductIDs = [
        liteMonthlyProductID,
        proMonthlyProductID,
        maxMonthlyProductID
    ]
    static let restorableProductIDs = legacySubscriptionProductIDs + [verifiedMonthlyProductID]
    static let allProductIDs = legacySubscriptionProductIDs
        + visibleCreditPacks.map(\.productID)
        + [verifiedMonthlyProductID]

    static func kind(for productID: String) -> IAPProductKind {
        if let pack = visibleCreditPacks.first(where: { $0.productID == productID }) {
            return .creditPack(pack)
        }
        if legacySubscriptionProductIDs.contains(productID) {
            return .legacySubscription
        }
        if productID == verifiedMonthlyProductID {
            return .verificationSubscription
        }
        return .unknown
    }

    static func shouldReplayUnfinishedTransaction(
        productID: String,
        hasRevocation: Bool = false
    ) -> Bool {
        if case .creditPack = kind(for: productID) {
            return true
        }
        return productID == verifiedMonthlyProductID && hasRevocation
    }

    static func shouldReconcileRevocation(productID: String) -> Bool {
        if case .creditPack = kind(for: productID) {
            return true
        }
        return productID == verifiedMonthlyProductID
    }
}

enum IAPProductAvailability {
    static func missingCreditPackIDs<S: Sequence>(
        loadedProductIDs: S
    ) -> [String] where S.Element == String {
        let loaded = Set(loadedProductIDs)
        return IAPProductCatalog.visibleCreditPacks
            .map(\.productID)
            .filter { !loaded.contains($0) }
    }

    static func hasAnyCreditPack<S: Sequence>(
        loadedProductIDs: S
    ) -> Bool where S.Element == String {
        missingCreditPackIDs(loadedProductIDs: loadedProductIDs).count
            < IAPProductCatalog.visibleCreditPacks.count
    }
}

enum IAPSettingsPurchaseVisibilityPolicy {
    static let shouldShowRestorePurchases = true

    static func shouldShowManageSubscription(
        hasActiveLegacyAppStoreSubscription: Bool,
        hasActiveVerifiedAppStoreSubscription: Bool
    ) -> Bool {
        hasActiveLegacyAppStoreSubscription || hasActiveVerifiedAppStoreSubscription
    }
}

struct IAPActiveSubscriptionSnapshot: Equatable, Sendable {
    let productIDs: Set<String>

    init<S: Sequence>(productIDs: S) where S.Element == String {
        self.productIDs = Set(productIDs)
    }

    var hasActiveLegacySubscription: Bool {
        !productIDs.isDisjoint(with: IAPProductCatalog.legacySubscriptionProductIDs)
    }

    var hasActiveVerifiedSubscription: Bool {
        productIDs.contains(IAPProductCatalog.verifiedMonthlyProductID)
    }

    var hasAnyActiveSubscription: Bool {
        hasActiveLegacySubscription || hasActiveVerifiedSubscription
    }

    func recordingActivePurchase(productID: String) -> IAPActiveSubscriptionSnapshot {
        guard IAPProductCatalog.restorableProductIDs.contains(productID) else {
            return self
        }
        return IAPActiveSubscriptionSnapshot(productIDs: productIDs.union([productID]))
    }
}

@MainActor
final class IAPService: ObservableObject {
    nonisolated static let liteMonthlyProductID = IAPProductCatalog.liteMonthlyProductID
    nonisolated static let proMonthlyProductID = IAPProductCatalog.proMonthlyProductID
    nonisolated static let maxMonthlyProductID = IAPProductCatalog.maxMonthlyProductID
    nonisolated static let verifiedMonthlyProductID = IAPProductCatalog.verifiedMonthlyProductID
    nonisolated static let creditPackProductIDs = IAPProductCatalog.visibleCreditPacks.map(\.productID)
    nonisolated static let monthlyProductID = proMonthlyProductID
    nonisolated static let monthlyProductIDs = IAPProductCatalog.legacySubscriptionProductIDs
    nonisolated static let allProductIDs = IAPProductCatalog.allProductIDs

    nonisolated static let verifiedDisplayPrice = "1000 ₸"

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var activeSubscriptionSnapshot = IAPActiveSubscriptionSnapshot(
        productIDs: [String]()
    )
    @Published private(set) var isLoadingProducts: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published var lastError: String?

    var product: Product? { products[Self.proMonthlyProductID] }

    private var updatesTask: Task<Void, Never>?
    private let auth: Auth
    private let transactionLifecycle = IAPTransactionLifecycleCoordinator()

    private var baseURL: URL { X5Config.supabaseBaseURL }
    private var anonKey: String { X5Config.supabaseAnonKey }

    private enum ServerVerificationResult: Equatable {
        case applied
        case alreadyApplied
        case ownedByOther
        case sandboxTestNotBillable
        case failed
    }

    private struct ServerVerificationRequest: Encodable {
        let signedTransaction: String

        enum CodingKeys: String, CodingKey {
            case signedTransaction = "signed_transaction"
        }
    }

    private struct ServerVerificationResponse: Decodable {
        let status: String
        let error: String?
    }

    init(auth: Auth) {
        self.auth = auth
        startTransactionListener()
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        lastError = nil
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.allProductIDs)
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            if !IAPProductAvailability.hasAnyCreditPack(
                loadedProductIDs: products.keys
            ) {
                lastError = LocalizationService.shared.t("iap_products_unavailable")
            }
            await syncCurrentEntitlements(source: "load")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func product(id: String) -> Product? {
        products[id]
    }

    /// Initiates the App Store purchase flow and delivers the signed transaction through
    /// the server. Credit amounts and entitlement changes are derived server-side.
    /// The current X5 user id is bound to the StoreKit transaction via
    /// `appAccountToken` so subsequent restore / Transaction.updates events
    /// can verify the entitlement belongs to *this* user — preventing the
    /// "log in to a second X5 account on the same Apple ID and inherit Pro
    /// for free" exploit Diaz hit in build 43.
    func purchaseMonthly() async -> Bool {
        await purchase(productID: Self.proMonthlyProductID)
    }

    func purchase(productID: String) async -> Bool {
        lastError = nil
        guard let product = products[productID] else {
            lastError = LocalizationService.shared.t("iap_products_unavailable")
            return false
        }
        guard let appUserToken = currentUserToken() else {
            lastError = LocalizationService.shared.t("iap_signin_first")
            return false
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await IAPRepeatPurchaseCoordinator.perform(
                recoverUnfinished: { [self] in
                    await retryUnfinishedConsumables(
                        source: "purchase_unfinished",
                        requiredAppAccountToken: appUserToken
                    )
                },
                startPurchase: {
                    try await product.purchase(options: [
                        .appAccountToken(appUserToken)
                    ])
                }
            )
            guard let result else {
                if lastError == nil {
                    lastError = LocalizationService.shared.t("iap_delivery_pending")
                }
                return false
            }
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    guard IAPCreditPurchaseConfirmation.matchesSelectedProduct(
                        selected: productID, returned: transaction.productID
                    ) else {
                        // Leave delivery to the transaction listener; never report
                        // the selected pack as purchased for a different product.
                        lastError = LocalizationService.shared.t("iap_purchase_unverified")
                        DiagnosticLogger.log(event: "iap_product_mismatch", extra: [
                            "selected": productID, "returned": transaction.productID
                        ])
                        return false
                    }
                    let applyResult = await deliverVerifiedTransaction(
                        transaction: transaction,
                        signedTransaction: verification.jwsRepresentation,
                        source: "purchase"
                    )

                    if applyResult.isPurchaseSuccess,
                       IAPProductCatalog.kind(for: transaction.productID) == .verificationSubscription {
                        activeSubscriptionSnapshot = activeSubscriptionSnapshot.recordingActivePurchase(
                            productID: transaction.productID
                        )
                        await syncCurrentEntitlements(source: "purchase")
                        activeSubscriptionSnapshot = activeSubscriptionSnapshot.recordingActivePurchase(
                            productID: transaction.productID
                        )
                    }
                    return applyResult.isPurchaseSuccess
                } else {
                    lastError = LocalizationService.shared.t("iap_purchase_unverified")
                    return false
                }
            case .userCancelled:
                return false
            case .pending:
                lastError = LocalizationService.shared.t("iap_purchase_pending")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        lastError = nil
        do {
            _ = await retryUnfinishedConsumables(source: "restore_unfinished")
            try await AppStore.sync()
            let didReconcileRevocation = await syncRevokedStoreTransactions(
                source: "restore_revoked"
            )
            await syncCurrentEntitlements(source: "restore")
            if didReconcileRevocation {
                notifyStoreRefundReconciled()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startTransactionListener() {
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    let disposition = await self?.deliverVerifiedTransaction(
                        transaction: transaction,
                        signedTransaction: update.jwsRepresentation,
                        source: "update"
                    )
                    if disposition == .applied,
                       transaction.revocationDate != nil {
                        await self?.notifyStoreRefundReconciled()
                    }
                }
            }
        }
    }

    func syncCurrentEntitlements(source: String) async {
        var activeSubscriptionProductIDs = Set<String>()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if IAPProductCatalog.restorableProductIDs.contains(transaction.productID) {
                activeSubscriptionProductIDs.insert(transaction.productID)
            }
            _ = await deliverVerifiedTransaction(
                transaction: transaction,
                signedTransaction: result.jwsRepresentation,
                source: source
            )
        }
        activeSubscriptionSnapshot = IAPActiveSubscriptionSnapshot(
            productIDs: activeSubscriptionProductIDs
        )
    }

    /// `Transaction.all` is finite and includes finished purchases that Apple
    /// refunded while the app was offline. Stream every supported revocation
    /// through the idempotent server path so memory stays bounded without
    /// permanently dropping older refunds.
    @discardableResult
    func syncRevokedStoreTransactions(source: String) async -> Bool {
        var didReconcile = false
        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  IAPProductCatalog.shouldReconcileRevocation(
                    productID: transaction.productID
                  ),
                  transaction.revocationDate != nil else {
                continue
            }

            let disposition = await deliverVerifiedTransaction(
                transaction: transaction,
                signedTransaction: result.jwsRepresentation,
                source: source
            )
            didReconcile = didReconcile || disposition == .applied
        }
        return didReconcile
    }

    /// Consumables are not part of `Transaction.currentEntitlements`, and revoked
    /// subscriptions disappear from it. StoreKit keeps either transaction unfinished
    /// until the server confirms delivery.
    func retryUnfinishedConsumables(
        source: String,
        requiredAppAccountToken: UUID? = nil
    ) async -> Bool {
        var didDeliverEveryTransaction = true

        for await result in Transaction.unfinished {
            switch result {
            case .verified(let transaction):
                let shouldReplay: Bool
                if let requiredAppAccountToken {
                    shouldReplay = IAPPrePurchaseRecoveryPolicy.shouldRequireDelivery(
                        productID: transaction.productID,
                        transactionAppAccountToken: transaction.appAccountToken,
                        currentUserToken: requiredAppAccountToken
                    )
                } else {
                    shouldReplay = IAPProductCatalog.shouldReplayUnfinishedTransaction(
                        productID: transaction.productID,
                        hasRevocation: transaction.revocationDate != nil
                    )
                }
                guard shouldReplay else {
                    continue
                }

                let disposition = await deliverVerifiedTransaction(
                    transaction: transaction,
                    signedTransaction: result.jwsRepresentation,
                    source: source
                )
                if !disposition.shouldFinishTransaction {
                    didDeliverEveryTransaction = false
                }

            case .unverified(let transaction, let verificationError):
                if requiredAppAccountToken != nil {
                    // Purchase preflight only trusts a verified owner token.
                    // Leave this transaction pending for StoreKit to retry.
                    continue
                }
                guard IAPProductCatalog.shouldReplayUnfinishedTransaction(
                    productID: transaction.productID,
                    hasRevocation: transaction.revocationDate != nil
                ) else {
                    continue
                }

                // Never finish or charge again while StoreKit cannot verify a
                // pending consumable. A later tap/listener can retry it.
                didDeliverEveryTransaction = false
                lastError = LocalizationService.shared.t("iap_purchase_unverified")
                DiagnosticLogger.log(event: "iap_unfinished_unverified", extra: [
                    "source": source,
                    "product": transaction.productID,
                    "error": String(verificationError.localizedDescription.prefix(120))
                ])
            }
        }

        return didDeliverEveryTransaction
    }

    private func deliverVerifiedTransaction(
        transaction: StoreKit.Transaction,
        signedTransaction: String,
        source: String
    ) async -> IAPEntitlementDisposition {
        let deliveryUserID = auth.userId
        return await transactionLifecycle.deliver(
            transactionID: transaction.id,
            authenticatedUserID: deliveryUserID,
            revocationDate: transaction.revocationDate,
            verifyDelivery: { [self] in
                await processVerifiedTransaction(
                    transaction: transaction,
                    signedTransaction: signedTransaction,
                    source: source
                )
            },
            finish: {
                await transaction.finish()
            },
            didApply: { [weak self] in
                guard let self, let deliveryUserID,
                      self.auth.userId == deliveryUserID else { return }
                self.lastError = nil
                NotificationCenter.default.post(
                    name: .x5DidUpdateStoreEntitlements,
                    object: deliveryUserID
                )
            }
        )
    }

    private func processVerifiedTransaction(
        transaction: StoreKit.Transaction,
        signedTransaction: String,
        source: String
    ) async -> IAPEntitlementDisposition {
        switch IAPProductCatalog.kind(for: transaction.productID) {
        case .creditPack:
            return await applyCreditPack(
                transaction: transaction,
                signedTransaction: signedTransaction,
                source: source
            )
        case .legacySubscription:
            return await applySubscriptionEntitlement(
                transaction: transaction,
                signedTransaction: signedTransaction,
                source: source
            )
        case .verificationSubscription:
            return await applyVerifiedEntitlement(
                transaction: transaction,
                signedTransaction: signedTransaction,
                source: source
            )
        case .unknown:
            return .skipped
        }
    }

    /// Maps the signed-in X5 user id (Supabase UUID string) into the UUID
    /// type StoreKit's `appAccountToken` requires. Returns nil if no user is
    /// signed in OR the stored id can't be parsed as a UUID — in either case
    /// purchase is blocked rather than silently binding the entitlement to
    /// a wrong account.
    private func currentUserToken() -> UUID? {
        guard let raw = auth.userId else { return nil }
        return UUID(uuidString: raw)
    }

    /// Delivers a consumable through the exact-once server ledger. Unlike legacy
    /// subscriptions, a successful top-up never posts the Pro activation event.
    private func applyCreditPack(
        transaction: StoreKit.Transaction,
        signedTransaction: String,
        source: String
    ) async -> IAPEntitlementDisposition {
        guard IAPOwnershipRoutingPolicy.shouldVerifyOnServer(
            signedInUserID: auth.userId,
            transactionAppAccountToken: transaction.appAccountToken
        ) else {
            DiagnosticLogger.log(event: "iap_credit_pack_missing_session", extra: [
                "source": source,
                "product": transaction.productID
            ])
            lastError = LocalizationService.shared.t("iap_signin_restore")
            return .failed
        }

        let verificationResult = await verifyAppStoreTransaction(
            signedTransaction: signedTransaction,
            source: source,
            productID: transaction.productID
        )
        switch verificationResult {
        case .applied, .alreadyApplied:
            DiagnosticLogger.log(
                event: transaction.revocationDate == nil
                    ? "iap_credit_pack_applied"
                    : "iap_credit_pack_refund_applied",
                extra: [
                    "source": source,
                    "product": transaction.productID,
                    "server_verification": verificationResult == .applied ? "applied" : "already_applied"
                ]
            )
            return .applied
        case .ownedByOther:
            // A consumable cannot be restored from current entitlements. Leave it
            // unfinished so its owning X5 account can retry delivery after sign-in.
            return .failed
        case .sandboxTestNotBillable:
            // TestFlight uses Apple's Sandbox and never charges real money.
            // The server deliberately grants no spendable credits outside the
            // dedicated App Review account. Finish this test transaction so it
            // cannot block a later production purchase for the same product.
            return .skipped
        case .failed:
            return .failed
        }
    }

    /// Applies the verified subscription through the server-side, idempotent
    /// App Store transaction verifier. The client never writes protected
    /// profile fields or sends decoded transaction claims to the server.
    private func applySubscriptionEntitlement(
        transaction: StoreKit.Transaction,
        signedTransaction: String,
        source: String
    ) async -> IAPEntitlementDisposition {
        guard IAPOwnershipRoutingPolicy.shouldVerifyOnServer(
            signedInUserID: auth.userId,
            transactionAppAccountToken: transaction.appAccountToken
        ) else {
            DiagnosticLogger.log(event: "iap_subscription_missing_session", extra: [
                "source": source,
                "product": transaction.productID
            ])
            lastError = LocalizationService.shared.t("iap_signin_restore")
            return .failed
        }

        // Never decide mismatched-token ownership locally. The server checks
        // Apple's signed JWS against the permanent owner ledger and the exact
        // private allowlist for the two grandfathered legacy chains.
        if let token = transaction.appAccountToken,
           let userID = auth.userId,
           let buyerID = UUID(uuidString: userID),
           token != buyerID {
            DiagnosticLogger.log(event: "iap_subscription_token_mismatch_deferred_to_server", extra: [
                "source": source,
                "product": transaction.productID
            ])
        }

        let verificationResult = await verifyAppStoreTransaction(
            signedTransaction: signedTransaction,
            source: source,
            productID: transaction.productID
        )
        switch verificationResult {
        case .applied, .alreadyApplied:
            break
        case .ownedByOther, .sandboxTestNotBillable:
            return .skipped
        case .failed:
            return .failed
        }

        // The Edge Function verifies Apple's JWS and is the only writer of
        // plan, balance and subscription dates.
        DiagnosticLogger.log(event: "iap_subscription_applied", extra: [
            "source": source,
            "product": transaction.productID,
            "server_verification": verificationResult == .applied ? "applied" : "already_applied"
        ])
        NotificationCenter.default.post(name: .x5DidActivatePro, object: nil)
        return .applied
    }

    private func applyVerifiedEntitlement(
        transaction: StoreKit.Transaction,
        signedTransaction: String,
        source: String
    ) async -> IAPEntitlementDisposition {
        guard IAPOwnershipRoutingPolicy.shouldVerifyOnServer(
            signedInUserID: auth.userId,
            transactionAppAccountToken: transaction.appAccountToken
        ) else {
            DiagnosticLogger.log(event: "iap_verified_missing_session", extra: ["source": source])
            lastError = LocalizationService.shared.t("iap_signin_restore")
            return .failed
        }

        if let token = transaction.appAccountToken,
           let userID = auth.userId,
           let buyerID = UUID(uuidString: userID),
           token != buyerID {
            DiagnosticLogger.log(event: "iap_verified_token_mismatch_deferred_to_server", extra: [
                "source": source
            ])
        }

        let verificationResult = await verifyAppStoreTransaction(
            signedTransaction: signedTransaction,
            source: source,
            productID: transaction.productID
        )
        switch verificationResult {
        case .applied, .alreadyApplied:
            break
        case .ownedByOther, .sandboxTestNotBillable:
            return .skipped
        case .failed:
            return .failed
        }

        // Verified state is written by the same idempotent server claim.
        // Do not PATCH protected profile entitlement columns from the client.
        DiagnosticLogger.log(event: "iap_verified_applied", extra: [
            "source": source,
            "server_verification": verificationResult == .applied ? "applied" : "already_applied"
        ])
        return .applied
    }

    private func verifyAppStoreTransaction(
        signedTransaction: String,
        source: String,
        productID: String
    ) async -> ServerVerificationResult {
        let requestBody: Data
        do {
            requestBody = try JSONEncoder().encode(
                ServerVerificationRequest(signedTransaction: signedTransaction)
            )
        } catch {
            DiagnosticLogger.log(event: "iap_verification_request_encoding_failed", extra: [
                "source": source,
                "product": productID
            ])
            lastError = LocalizationService.shared.t("iap_delivery_pending")
            return .failed
        }

        var accessToken = auth.accessToken
        if accessToken == nil {
            accessToken = await auth.freshAccessToken()
        }
        guard var accessToken else {
            lastError = LocalizationService.shared.t("iap_signin_restore")
            return .failed
        }

        var retryCount = 0
        while true {
            var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/verify-app-store-transaction"))
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = requestBody

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let serverResponse = try? JSONDecoder().decode(ServerVerificationResponse.self, from: data)
                let status = serverResponse?.status
                let serverError = serverResponse?.error
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

                if IAPVerificationRetryPolicy.shouldRetry(statusCode: httpStatus, retryCount: retryCount) {
                    retryCount += 1
                    guard let refreshedToken = await auth.freshAccessToken() else {
                        lastError = LocalizationService.shared.t("iap_signin_restore")
                        return .failed
                    }
                    accessToken = refreshedToken
                    continue
                }

                if status == "owned_by_other" || serverError == "account_token_mismatch" {
                    DiagnosticLogger.log(event: "iap_verification_owned_by_other", extra: [
                        "source": source,
                        "product": productID
                    ])
                    lastError = accountMismatchError
                    return .ownedByOther
                }

                if status == "sandbox_test_not_billable" {
                    DiagnosticLogger.log(event: "iap_sandbox_test_not_billable", extra: [
                        "source": source,
                        "product": productID
                    ])
                    lastError = LocalizationService.shared.t("iap_sandbox_test_not_billable")
                    return .sandboxTestNotBillable
                }

                guard (200..<300).contains(httpStatus) else {
                    DiagnosticLogger.log(event: "iap_verification_failed", extra: [
                        "source": source,
                        "product": productID,
                        "status": "\(httpStatus)",
                        "server_error": String((serverError ?? "unknown").prefix(80))
                    ])
                    lastError = LocalizationService.shared.t("iap_delivery_pending")
                    return .failed
                }

                switch status {
                case "applied":
                    return .applied
                case "already_applied":
                    return .alreadyApplied
                default:
                    DiagnosticLogger.log(event: "iap_verification_unknown_response", extra: [
                        "source": source,
                        "product": productID,
                        "response": String((status ?? "").prefix(80))
                    ])
                    lastError = LocalizationService.shared.t("iap_delivery_pending")
                    return .failed
                }
            } catch {
                DiagnosticLogger.log(event: "iap_verification_error", extra: [
                    "source": source,
                    "product": productID,
                    "error": String(error.localizedDescription.prefix(120))
                ])
                lastError = LocalizationService.shared.t("iap_delivery_pending")
                return .failed
            }
        }
    }

    private var accountMismatchError: String {
        LocalizationService.shared.t("iap_account_mismatch")
    }

    private func notifyStoreRefundReconciled() {
        NotificationCenter.default.post(
            name: .x5DidReconcileStoreRefund,
            object: nil
        )
    }

}

extension Notification.Name {
    static let x5DidUpdateStoreEntitlements = Notification.Name("x5.iap.did_update_entitlements")
    static let x5DidActivatePro = Notification.Name("x5.iap.did_activate_pro")
    static let x5DidReconcileStoreRefund = Notification.Name(
        "x5.iap.did_reconcile_store_refund"
    )
}
