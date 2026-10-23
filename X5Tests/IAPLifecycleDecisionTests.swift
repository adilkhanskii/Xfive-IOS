import Foundation
import XCTest
@testable import X5

final class IAPLifecycleDecisionTests: XCTestCase {
    @MainActor
    func testSuccessfulBackgroundDeliveryRefreshesProfileExactlyOnce() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        var events: [String] = []
        for _ in 0..<3 {
            _ = await lifecycle.deliver(
                transactionID: 901,
                authenticatedUserID: "owner",
                verifyDelivery: { events.append("server"); return .applied },
                finish: { events.append("finish") },
                didApply: { events.append("refresh") }
            )
        }
        XCTAssertEqual(events, ["server", "finish", "refresh"])
    }

    @MainActor
    func testFailedAndSkippedDeliveryDoNotPublishSuccessButRetryDoes() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        var refreshes = 0
        for result in [IAPEntitlementDisposition.failed, .skipped, .applied] {
            _ = await lifecycle.deliver(
                transactionID: 902,
                authenticatedUserID: "owner",
                verifyDelivery: { result },
                finish: {},
                didApply: { refreshes += 1 }
            )
            XCTAssertEqual(refreshes, result == .applied ? 1 : 0)
        }
    }

    @MainActor
    func testConcurrentDeliveryPublishesOneProfileRefresh() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        var refreshes = 0
        var finishes = 0
        let delivery: () async -> IAPEntitlementDisposition = {
            await lifecycle.deliver(
                transactionID: 903,
                authenticatedUserID: "owner",
                verifyDelivery: { await Task.yield(); return .applied },
                finish: { finishes += 1 },
                didApply: { refreshes += 1 }
            )
        }
        async let first = delivery()
        async let second = delivery()
        _ = await (first, second)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(refreshes, 1)
    }

    func testPrePurchaseRecoveryRequiresOnlyConsumablesBoundToCurrentX5Account() {
        let currentAccount = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let otherAccount = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let creditPack = "com.x5studio.app.credits.1000"

        XCTAssertTrue(
            IAPPrePurchaseRecoveryPolicy.shouldRequireDelivery(
                productID: creditPack,
                transactionAppAccountToken: currentAccount,
                currentUserToken: currentAccount
            )
        )
        XCTAssertFalse(
            IAPPrePurchaseRecoveryPolicy.shouldRequireDelivery(
                productID: creditPack,
                transactionAppAccountToken: otherAccount,
                currentUserToken: currentAccount
            )
        )
        XCTAssertFalse(
            IAPPrePurchaseRecoveryPolicy.shouldRequireDelivery(
                productID: creditPack,
                transactionAppAccountToken: nil,
                currentUserToken: currentAccount
            )
        )
        XCTAssertFalse(
            IAPPrePurchaseRecoveryPolicy.shouldRequireDelivery(
                productID: IAPService.verifiedMonthlyProductID,
                transactionAppAccountToken: currentAccount,
                currentUserToken: currentAccount
            )
        )
    }

    @MainActor
    func testRepeatPurchaseRecoversUnfinishedTransactionsBeforeEveryStoreKitAttempt() async {
        var events: [String] = []

        for _ in 0..<2 {
            let result: String? = await IAPRepeatPurchaseCoordinator.perform(
                recoverUnfinished: {
                    events.append("recover")
                    return true
                },
                startPurchase: {
                    events.append("purchase")
                    return "purchased"
                }
            )

            XCTAssertEqual(result, "purchased")
        }

        XCTAssertEqual(events, [
            "recover", "purchase",
            "recover", "purchase"
        ])
    }

    @MainActor
    func testRepeatPurchaseDoesNotStartNewChargeWhileUnfinishedDeliveryIsPending() async {
        var didStartPurchase = false

        let result: String? = await IAPRepeatPurchaseCoordinator.perform(
            recoverUnfinished: { false },
            startPurchase: {
                didStartPurchase = true
                return "purchased"
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(didStartPurchase)
    }

    @MainActor
    func testFailedRecoveryDoesNotCreateAStickyLocalProductLock() async {
        var recoveryResults = [false, true]
        var purchaseCount = 0

        let firstAttempt: String? = await IAPRepeatPurchaseCoordinator.perform(
            recoverUnfinished: { recoveryResults.removeFirst() },
            startPurchase: {
                purchaseCount += 1
                return "purchased"
            }
        )
        let secondAttempt: String? = await IAPRepeatPurchaseCoordinator.perform(
            recoverUnfinished: { recoveryResults.removeFirst() },
            startPurchase: {
                purchaseCount += 1
                return "purchased"
            }
        )

        XCTAssertNil(firstAttempt)
        XCTAssertEqual(secondAttempt, "purchased")
        XCTAssertEqual(purchaseCount, 1)
    }

    @MainActor
    func testServerDeliveryFailureLeavesConsumableUnfinished() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        var verificationCalls = 0
        var finishCalls = 0

        let disposition = await lifecycle.deliver(
            transactionID: 101,
            authenticatedUserID: "11111111-1111-4111-8111-111111111111",
            verifyDelivery: {
                verificationCalls += 1
                return .failed
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(disposition, .failed)
        XCTAssertEqual(verificationCalls, 1)
        XCTAssertEqual(finishCalls, 0)
    }

    @MainActor
    func testRetryAfterServerAlreadyAppliedFinishesTransactionExactlyOnce() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        var verificationResults: [IAPEntitlementDisposition] = [.failed, .applied]
        var verificationCalls = 0
        var finishCalls = 0

        let firstAttempt = await lifecycle.deliver(
            transactionID: 202,
            authenticatedUserID: "11111111-1111-4111-8111-111111111111",
            verifyDelivery: {
                verificationCalls += 1
                return verificationResults.removeFirst()
            },
            finish: { finishCalls += 1 }
        )
        let retryAfterAlreadyApplied = await lifecycle.deliver(
            transactionID: 202,
            authenticatedUserID: "11111111-1111-4111-8111-111111111111",
            verifyDelivery: {
                verificationCalls += 1
                // `.applied` is the client disposition for both the server's
                // `applied` and exact-once `already_applied` responses.
                return verificationResults.removeFirst()
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(firstAttempt, .failed)
        XCTAssertEqual(retryAfterAlreadyApplied, .applied)
        XCTAssertEqual(verificationCalls, 2)
        XCTAssertEqual(finishCalls, 1)
    }

    @MainActor
    func testDuplicateDeliveryDoesNotVerifyOrFinishTransactionTwice() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        let accountID = "11111111-1111-4111-8111-111111111111"
        var verificationCalls = 0
        var finishCalls = 0

        let firstDelivery = await lifecycle.deliver(
            transactionID: 303,
            authenticatedUserID: accountID,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )
        let duplicateDelivery = await lifecycle.deliver(
            transactionID: 303,
            authenticatedUserID: accountID,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(firstDelivery, .applied)
        XCTAssertEqual(duplicateDelivery, .applied)
        XCTAssertEqual(verificationCalls, 1)
        XCTAssertEqual(finishCalls, 1)
    }

    @MainActor
    func testAppliedTransactionIsReverifiedWhenAuthenticatedAccountChanges() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        let accountA = "11111111-1111-4111-8111-111111111111"
        let accountB = "22222222-2222-4222-8222-222222222222"
        var verificationCalls = 0
        var finishCalls = 0

        let firstAccount = await lifecycle.deliver(
            transactionID: 353,
            authenticatedUserID: accountA,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )
        let secondAccount = await lifecycle.deliver(
            transactionID: 353,
            authenticatedUserID: accountB,
            verifyDelivery: {
                verificationCalls += 1
                // The server maps a restorable entitlement owned by account A
                // to `.skipped` when account B attempts to claim it.
                return .skipped
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(firstAccount, .applied)
        XCTAssertEqual(secondAccount, .skipped)
        XCTAssertFalse(secondAccount.isPurchaseSuccess)
        XCTAssertEqual(verificationCalls, 2)
        XCTAssertEqual(finishCalls, 2)
    }

    @MainActor
    func testRejectedCrossAccountConsumableRemainsUnfinished() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        let accountA = "11111111-1111-4111-8111-111111111111"
        let accountB = "22222222-2222-4222-8222-222222222222"
        var verificationCalls = 0
        var finishCalls = 0

        _ = await lifecycle.deliver(
            transactionID: 363,
            authenticatedUserID: accountA,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )
        let secondAccount = await lifecycle.deliver(
            transactionID: 363,
            authenticatedUserID: accountB,
            verifyDelivery: {
                verificationCalls += 1
                // Consumable ownership rejection maps to `.failed`, keeping
                // StoreKit delivery retryable for the owning X5 account.
                return .failed
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(secondAccount, .failed)
        XCTAssertFalse(secondAccount.isPurchaseSuccess)
        XCTAssertEqual(verificationCalls, 2)
        XCTAssertEqual(finishCalls, 1)
    }

    @MainActor
    func testSkippedOwnershipCanBeVerifiedAgainAfterAccountChanges() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        let otherAccountID = "11111111-1111-4111-8111-111111111111"
        let ownerAccountID = "22222222-2222-4222-8222-222222222222"
        var verificationResults: [IAPEntitlementDisposition] = [.skipped, .applied]
        var verificationCalls = 0
        var finishCalls = 0

        let otherAccount = await lifecycle.deliver(
            transactionID: 404,
            authenticatedUserID: otherAccountID,
            verifyDelivery: {
                verificationCalls += 1
                return verificationResults.removeFirst()
            },
            finish: { finishCalls += 1 }
        )
        let owningAccount = await lifecycle.deliver(
            transactionID: 404,
            authenticatedUserID: ownerAccountID,
            verifyDelivery: {
                verificationCalls += 1
                return verificationResults.removeFirst()
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(otherAccount, .skipped)
        XCTAssertEqual(owningAccount, .applied)
        XCTAssertEqual(verificationCalls, 2)
        XCTAssertEqual(finishCalls, 2)
    }

    func testAppliedEntitlementFinishesTransactionAndReportsPurchaseSuccess() {
        let disposition = IAPEntitlementDisposition.applied

        XCTAssertTrue(disposition.shouldFinishTransaction)
        XCTAssertTrue(disposition.isPurchaseSuccess)
    }

    func testSkippedEntitlementFinishesTransactionWithoutReportingPurchaseSuccess() {
        let disposition = IAPEntitlementDisposition.skipped

        XCTAssertTrue(disposition.shouldFinishTransaction)
        XCTAssertFalse(disposition.isPurchaseSuccess)
    }

    func testFailedEntitlementRemainsPendingAndDoesNotReportPurchaseSuccess() {
        let disposition = IAPEntitlementDisposition.failed

        XCTAssertFalse(disposition.shouldFinishTransaction)
        XCTAssertFalse(disposition.isPurchaseSuccess)
    }

    func testUnauthorizedVerificationRetriesExactlyOnce() {
        XCTAssertTrue(IAPVerificationRetryPolicy.shouldRetry(statusCode: 401, retryCount: 0))
        XCTAssertFalse(IAPVerificationRetryPolicy.shouldRetry(statusCode: 401, retryCount: 1))
    }

    func testNonAuthorizationFailureDoesNotRefreshToken() {
        XCTAssertFalse(IAPVerificationRetryPolicy.shouldRetry(statusCode: 500, retryCount: 0))
    }

    func testMismatchedLegacyTokenIsDeferredToServerOwnershipVerification() {
        let signedInUserID = "11111111-1111-4111-8111-111111111111"
        let historicalToken = UUID(uuidString: "22222222-2222-4222-8222-222222222222")

        XCTAssertTrue(
            IAPOwnershipRoutingPolicy.shouldVerifyOnServer(
                signedInUserID: signedInUserID,
                transactionAppAccountToken: historicalToken
            )
        )
    }

    func testOwnershipVerificationDoesNotStartWithoutSignedInUser() {
        XCTAssertFalse(
            IAPOwnershipRoutingPolicy.shouldVerifyOnServer(
                signedInUserID: nil,
                transactionAppAccountToken: nil
            )
        )
    }

    func testVerifiedPurchaseIsRecordedInActiveSubscriptionSnapshotImmediately() {
        let initial = IAPActiveSubscriptionSnapshot(productIDs: [String]())

        let updated = initial.recordingActivePurchase(
            productID: IAPService.verifiedMonthlyProductID
        )

        XCTAssertTrue(updated.hasActiveVerifiedSubscription)
        XCTAssertTrue(updated.hasAnyActiveSubscription)
    }

    func testFailedProfileReloadUsesPendingRefreshConfirmation() {
        XCTAssertEqual(
            IAPCreditPurchaseConfirmation.messageKey(profileReloadSucceeded: false),
            "credit_store_success_refresh_pending"
        )
        XCTAssertEqual(
            IAPCreditPurchaseConfirmation.messageKey(profileReloadSucceeded: true),
            "credit_store_success_message"
        )
    }

    @MainActor
    func testRevocationReverifiesACompletedTransactionExactlyOnce() async {
        let lifecycle = IAPTransactionLifecycleCoordinator()
        let accountID = "11111111-1111-4111-8111-111111111111"
        let revokedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var verificationCalls = 0
        var finishCalls = 0

        _ = await lifecycle.deliver(
            transactionID: 505,
            authenticatedUserID: accountID,
            revocationDate: nil,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )
        _ = await lifecycle.deliver(
            transactionID: 505,
            authenticatedUserID: accountID,
            revocationDate: revokedAt,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )
        _ = await lifecycle.deliver(
            transactionID: 505,
            authenticatedUserID: accountID,
            revocationDate: revokedAt,
            verifyDelivery: {
                verificationCalls += 1
                return .applied
            },
            finish: { finishCalls += 1 }
        )

        XCTAssertEqual(verificationCalls, 2)
        XCTAssertEqual(finishCalls, 2)
    }
}
