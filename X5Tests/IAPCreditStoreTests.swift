import XCTest
@testable import X5

final class IAPCreditStoreTests: XCTestCase {
    func testPurchaseConfirmationRequiresTheSelectedProduct() {
        XCTAssertTrue(IAPCreditPurchaseConfirmation.matchesSelectedProduct(
            selected: "credits.1000", returned: "credits.1000"))
        XCTAssertFalse(IAPCreditPurchaseConfirmation.matchesSelectedProduct(
            selected: "credits.1000", returned: "credits.5000"))
        XCTAssertFalse(IAPCreditPurchaseConfirmation.matchesSelectedProduct(
            selected: "credits.1000", returned: IAPService.verifiedMonthlyProductID))
    }

    func testVisibleStoreContainsExactlyThreeOrderedConsumablePacks() {
        XCTAssertEqual(
            IAPProductCatalog.visibleCreditPacks.map(\.productID),
            [
                "com.x5studio.app.credits.1000",
                "com.x5studio.app.credits.2000",
                "com.x5studio.app.credits.5000"
            ]
        )
        XCTAssertEqual(IAPProductCatalog.visibleCreditPacks.map(\.credits), [1_000, 2_000, 5_000])

        for pack in IAPProductCatalog.visibleCreditPacks {
            XCTAssertEqual(IAPProductCatalog.kind(for: pack.productID), .creditPack(pack))
        }
    }

    func testLegacySubscriptionsStayLoadedAndRestorableButAreHiddenFromStore() {
        let legacyIDs = Set(IAPProductCatalog.legacySubscriptionProductIDs)
        let loadedIDs = Set(IAPProductCatalog.allProductIDs)
        let restorableIDs = Set(IAPProductCatalog.restorableProductIDs)
        let visibleIDs = Set(IAPProductCatalog.visibleCreditPacks.map(\.productID))

        XCTAssertTrue(legacyIDs.isSubset(of: loadedIDs))
        XCTAssertTrue(legacyIDs.isSubset(of: restorableIDs))
        XCTAssertTrue(legacyIDs.isDisjoint(with: visibleIDs))
    }

    func testVerificationRemainsASeparateSubscriptionWithOneThousandTengeFallback() {
        XCTAssertEqual(
            IAPProductCatalog.kind(for: IAPService.verifiedMonthlyProductID),
            .verificationSubscription
        )
        XCTAssertEqual(IAPService.verifiedDisplayPrice, "1000 ₸")
        XCTAssertFalse(
            IAPProductCatalog.visibleCreditPacks
                .map(\.productID)
                .contains(IAPService.verifiedMonthlyProductID)
        )
    }

    func testCreditPackRoutesToBalanceDeliveryWithoutProActivation() {
        let kind = IAPProductCatalog.kind(for: "com.x5studio.app.credits.2000")

        XCTAssertEqual(kind, .creditPack(IAPCreditPack(
            productID: "com.x5studio.app.credits.2000",
            credits: 2_000,
            fallbackDisplayPrice: "2000 ₸"
        )))
        XCTAssertFalse(kind.activatesLegacyPro)
        XCTAssertTrue(IAPProductCatalog.kind(for: IAPService.proMonthlyProductID).activatesLegacyPro)
    }

    func testProductAvailabilityReportsMissingPacksInCatalogOrder() {
        let loaded = [
            "com.x5studio.app.credits.2000",
            IAPService.verifiedMonthlyProductID
        ]

        XCTAssertEqual(
            IAPProductAvailability.missingCreditPackIDs(loadedProductIDs: loaded),
            [
                "com.x5studio.app.credits.1000",
                "com.x5studio.app.credits.5000"
            ]
        )
        XCTAssertTrue(IAPProductAvailability.hasAnyCreditPack(loadedProductIDs: loaded))
        XCTAssertFalse(IAPProductAvailability.hasAnyCreditPack(loadedProductIDs: [String]()))
    }

    func testUnfinishedReplayIncludesConsumablesAndOnlyRevokedVerification() {
        for pack in IAPProductCatalog.visibleCreditPacks {
            XCTAssertTrue(
                IAPProductCatalog.shouldReplayUnfinishedTransaction(
                    productID: pack.productID,
                    hasRevocation: false
                )
            )
        }

        XCTAssertFalse(
            IAPProductCatalog.shouldReplayUnfinishedTransaction(
                productID: IAPService.proMonthlyProductID,
                hasRevocation: true
            )
        )
        XCTAssertFalse(
            IAPProductCatalog.shouldReplayUnfinishedTransaction(
                productID: IAPService.verifiedMonthlyProductID,
                hasRevocation: false
            )
        )
        XCTAssertTrue(
            IAPProductCatalog.shouldReplayUnfinishedTransaction(
                productID: IAPService.verifiedMonthlyProductID,
                hasRevocation: true
            )
        )
    }

    func testOfflineRevocationReconciliationIncludesCreditPacksAndVerificationOnly() {
        for pack in IAPProductCatalog.visibleCreditPacks {
            XCTAssertTrue(
                IAPProductCatalog.shouldReconcileRevocation(productID: pack.productID)
            )
        }
        XCTAssertTrue(
            IAPProductCatalog.shouldReconcileRevocation(
                productID: IAPService.verifiedMonthlyProductID
            )
        )
        for productID in IAPProductCatalog.legacySubscriptionProductIDs {
            XCTAssertFalse(
                IAPProductCatalog.shouldReconcileRevocation(productID: productID)
            )
        }
        XCTAssertFalse(
            IAPProductCatalog.shouldReconcileRevocation(productID: "unknown.product")
        )
    }

    func testBackendFailureLeavesUnfinishedConsumablePendingForRetry() {
        XCTAssertFalse(IAPEntitlementDisposition.failed.shouldFinishTransaction)
        XCTAssertTrue(IAPEntitlementDisposition.applied.shouldFinishTransaction)
        XCTAssertTrue(IAPEntitlementDisposition.skipped.shouldFinishTransaction)
        XCTAssertFalse(IAPEntitlementDisposition.skipped.isPurchaseSuccess)
    }

    func testSettingsKeepsRestoreAvailableButManagesOnlyActiveSubscriptions() {
        XCTAssertTrue(IAPSettingsPurchaseVisibilityPolicy.shouldShowRestorePurchases)
        XCTAssertFalse(
            IAPSettingsPurchaseVisibilityPolicy.shouldShowManageSubscription(
                hasActiveLegacyAppStoreSubscription: false,
                hasActiveVerifiedAppStoreSubscription: false
            )
        )
        XCTAssertTrue(
            IAPSettingsPurchaseVisibilityPolicy.shouldShowManageSubscription(
                hasActiveLegacyAppStoreSubscription: true,
                hasActiveVerifiedAppStoreSubscription: false
            )
        )
        XCTAssertTrue(
            IAPSettingsPurchaseVisibilityPolicy.shouldShowManageSubscription(
                hasActiveLegacyAppStoreSubscription: false,
                hasActiveVerifiedAppStoreSubscription: true
            )
        )
    }

    func testStoreKitEntitlementSnapshotSeparatesLegacyAndVerifiedOwnership() {
        let snapshot = IAPActiveSubscriptionSnapshot(productIDs: [
            IAPService.proMonthlyProductID,
            IAPService.verifiedMonthlyProductID
        ])

        XCTAssertTrue(snapshot.hasActiveLegacySubscription)
        XCTAssertTrue(snapshot.hasActiveVerifiedSubscription)
        XCTAssertFalse(
            IAPActiveSubscriptionSnapshot(productIDs: [String]()).hasAnyActiveSubscription
        )
    }

    @MainActor
    func testCreditStoreAndVerificationStringsExistInEverySupportedLanguage() {
        let requiredKeys = [
            "credit_store_title",
            "credit_store_description",
            "credit_store_balance",
            "credit_store_pack_credits",
            "credit_store_one_time",
            "credit_store_buy",
            "credit_store_unavailable",
            "credit_store_success_title",
            "credit_store_success_message",
            "credit_store_success_refresh_pending",
            "iap_products_unavailable",
            "iap_sandbox_test_not_billable",
            "profile_store_title",
            "profile_store_subtitle",
            "settings_restore_subscriptions",
            "verified_price_period",
            "verified_purchase_note",
            "verified_buy_button",
            "verified_cancel_note",
            "verified_restore",
            "verified_manage",
            "verified_subscription_terms",
            "verified_benefit_tasks"
        ]

        for language in AppLanguage.allCases {
            for key in requiredKeys {
                XCTAssertNotNil(
                    LocalizationService.dict[language]?[key],
                    "Missing \(key) for \(language.rawValue)"
                )
            }
        }
    }
}
