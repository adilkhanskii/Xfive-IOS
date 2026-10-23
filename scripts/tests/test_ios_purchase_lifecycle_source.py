from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
IAP_SERVICE = ROOT / "X5" / "Services" / "IAPService.swift"
X5_APP = ROOT / "X5" / "X5App.swift"
PAYWALL = ROOT / "X5" / "Views" / "PaywallView.swift"
PROFILE = ROOT / "X5" / "Services" / "UserProfile.swift"
LOCALIZATION = ROOT / "X5" / "Services" / "LocalizationService.swift"


class IOSPurchaseLifecycleSourceTests(unittest.TestCase):
    def test_all_storekit_delivery_paths_use_the_mockable_lifecycle(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")

        self.assertIn("final class IAPTransactionLifecycleCoordinator", source)
        self.assertIn("private let transactionLifecycle", source)
        self.assertGreaterEqual(source.count("deliverVerifiedTransaction("), 5)
        self.assertEqual(source.count("await transaction.finish()"), 1)
        self.assertIn("if disposition == .applied", source)

    def test_transaction_completion_cache_is_scoped_to_authenticated_account(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")

        self.assertIn("struct IAPTransactionDeliveryKey: Hashable", source)
        self.assertIn("authenticatedUserID: String?", source)
        # Ownership is captured once before suspension and reused for UI delivery.
        self.assertIn("let deliveryUserID = auth.userId", source)
        self.assertIn("authenticatedUserID: deliveryUserID", source)
        self.assertIn("self.auth.userId == deliveryUserID", source)

    def test_transaction_completion_cache_distinguishes_later_revocation(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")

        self.assertIn("let revocationDate: Date?", source)
        self.assertIn("revocationDate: transaction.revocationDate", source)

    def test_verified_purchase_records_and_syncs_active_entitlements(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")

        self.assertIn("recordingActivePurchase", source)
        self.assertIn('await syncCurrentEntitlements(source: "purchase")', source)

    def test_store_refunds_are_retryable_and_refresh_the_server_profile(self):
        service = IAP_SERVICE.read_text(encoding="utf-8")
        app = X5_APP.read_text(encoding="utf-8")

        self.assertIn("hasRevocation: transaction.revocationDate != nil", service)
        self.assertIn("transaction.revocationDate != nil", service)
        self.assertIn("Transaction.all", service)
        self.assertNotIn("IAPRevocationReconciliationPolicy", service)
        self.assertNotIn("var revocations:", service)
        self.assertIn("let disposition = await deliverVerifiedTransaction", service)
        self.assertIn("shouldReconcileRevocation", service)
        self.assertIn("syncRevokedStoreTransactions", service)
        self.assertIn(".x5DidReconcileStoreRefund", service)
        self.assertIn(".x5DidReconcileStoreRefund", app)
        self.assertIn("iap.syncRevokedStoreTransactions", app)
        self.assertIn("syncStoreKitAndProfile", app)

    def test_restore_retries_unfinished_credit_packs_before_entitlement_sync(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")
        restore_start = source.index("    func restore() async {")
        restore_end = source.index("    private func startTransactionListener()", restore_start)
        restore = source[restore_start:restore_end]

        retry = 'await retryUnfinishedConsumables(source: "restore_unfinished")'
        store_sync = "try await AppStore.sync()"
        entitlements = 'await syncCurrentEntitlements(source: "restore")'
        self.assertIn(retry, restore)
        self.assertIn(store_sync, restore)
        self.assertIn(entitlements, restore)
        self.assertLess(restore.index(retry), restore.index(store_sync))
        self.assertLess(restore.index(retry), restore.index(entitlements))

    def test_every_purchase_recovers_unfinished_consumables_before_storekit(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")
        purchase_start = source.index("    func purchase(productID: String) async -> Bool {")
        purchase_end = source.index("    func restore() async {", purchase_start)
        purchase = source[purchase_start:purchase_end]

        recovery = 'recoverUnfinished: { [self] in'
        retry = 'source: "purchase_unfinished"'
        owner = "requiredAppAccountToken: appUserToken"
        storekit = "product.purchase(options:"
        self.assertIn("IAPRepeatPurchaseCoordinator.perform(", purchase)
        self.assertIn(recovery, purchase)
        self.assertIn(retry, purchase)
        self.assertIn(owner, purchase)
        self.assertIn(storekit, purchase)
        self.assertLess(purchase.index(recovery), purchase.index(storekit))
        self.assertLess(purchase.index(retry), purchase.index(storekit))

    def test_preflight_skips_other_account_consumables_without_finishing_them(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")
        retry_start = source.index("    func retryUnfinishedConsumables(")
        retry_end = source.index("    private func deliverVerifiedTransaction(", retry_start)
        retry = source[retry_start:retry_end]

        self.assertIn("requiredAppAccountToken: UUID? = nil", retry)
        self.assertIn("IAPPrePurchaseRecoveryPolicy.shouldRequireDelivery(", retry)
        self.assertIn("transactionAppAccountToken: transaction.appAccountToken", retry)
        self.assertIn("currentUserToken: requiredAppAccountToken", retry)
        self.assertIn("if requiredAppAccountToken != nil", retry)

    def test_unfinished_recovery_blocks_new_charge_until_delivery_finishes(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")
        retry_start = source.index("    func retryUnfinishedConsumables(")
        retry_end = source.index("    private func deliverVerifiedTransaction(", retry_start)
        retry = source[retry_start:retry_end]

        self.assertIn("async -> Bool", retry)
        self.assertIn("var didDeliverEveryTransaction = true", retry)
        self.assertIn("disposition.shouldFinishTransaction", retry)
        self.assertIn("didDeliverEveryTransaction = false", retry)
        self.assertIn("return didDeliverEveryTransaction", retry)

    def test_repeatable_consumables_have_no_daily_or_local_product_lock(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")
        purchase_start = source.index("    func purchase(productID: String) async -> Bool {")
        purchase_end = source.index("    func restore() async {", purchase_start)
        purchase = source[purchase_start:purchase_end]

        self.assertNotIn("UserDefaults", purchase)
        self.assertNotIn("Calendar.", purchase)
        self.assertNotIn("lastPurchase", purchase)
        self.assertNotIn("purchasedProductIDs", purchase)

    def test_failed_profile_reload_has_truthful_confirmation_copy(self):
        paywall = PAYWALL.read_text(encoding="utf-8")
        profile = PROFILE.read_text(encoding="utf-8")
        localization = LOCALIZATION.read_text(encoding="utf-8")

        self.assertIn("profileReloadSucceeded", paywall)
        self.assertIn("-> Bool", profile)
        self.assertEqual(localization.count('"credit_store_success_refresh_pending"'), 3)

    def test_missing_store_products_are_recoverable_instead_of_silent(self):
        service = IAP_SERVICE.read_text(encoding="utf-8")
        paywall = PAYWALL.read_text(encoding="utf-8")

        self.assertIn("@Published private(set) var isLoadingProducts", service)
        self.assertIn("guard !isLoadingProducts else { return }", service)
        self.assertIn("IAPProductAvailability.hasAnyCreditPack", service)
        self.assertIn('lastError = LocalizationService.shared.t("iap_products_unavailable")', service)
        self.assertIn("Task { await reloadProducts() }", paywall)
        self.assertIn("hasMissingCreditPacks", paywall)
        self.assertIn(".disabled(iap.isLoadingProducts || iap.isPurchasing)", paywall)

    def test_server_rejection_code_is_kept_in_safe_diagnostics(self):
        source = IAP_SERVICE.read_text(encoding="utf-8")

        self.assertIn("let error: String?", source)
        self.assertIn('"server_error": String((serverError ?? "unknown").prefix(80))', source)


if __name__ == "__main__":
    unittest.main()
