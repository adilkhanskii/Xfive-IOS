import XCTest
@testable import X5

final class UserProfileEntitlementTests: XCTestCase {
    func testActivePaidTiersUseServerExpirationDate() {
        XCTAssertTrue(makeProfile(plan: "lite", endDate: "2099-01-01T00:00:00Z").isPro)
        XCTAssertTrue(makeProfile(plan: "pro", endDate: "2099-01-01T00:00:00.000Z").isPro)
        XCTAssertTrue(makeProfile(plan: "max", endDate: "2099-01-01T00:00:00Z").isPro)
        XCTAssertFalse(makeProfile(plan: "max", endDate: "2000-01-01T00:00:00Z").isPro)
    }

    func testLegacyPaidProfileWithoutExpirationKeepsAccess() {
        XCTAssertTrue(makeProfile(plan: "pro", endDate: nil).isPro)
    }

    func testMalformedExpirationFailsClosedForTrackedSubscription() {
        XCTAssertFalse(makeProfile(plan: "pro", endDate: "not-a-date").isPro)
    }

    func testBlackRemainsLifetimeAndFreeRemainsLocked() {
        XCTAssertTrue(makeProfile(plan: "black", endDate: "2000-01-01T00:00:00Z").isPro)
        XCTAssertFalse(makeProfile(plan: "free", endDate: "2099-01-01T00:00:00Z").isPro)
    }

    func testHubSpecialistUsesTheSameServerExpirationRule() {
        var specialist = makeSpecialist(plan: "pro")
        specialist.subscriptionEndDate = "2000-01-01T00:00:00Z"
        XCTAssertFalse(specialist.isPro)

        specialist.subscriptionEndDate = "2099-01-01T00:00:00Z"
        XCTAssertTrue(specialist.isPro)
    }

    func testVerifiedBadgeRequiresFlagAndFutureExpirationEverywhere() {
        let now = ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")!

        XCTAssertTrue(UserProfile.isVerifiedBadgeActive(
            isVerified: true,
            until: "2026-08-16T00:00:00Z",
            now: now
        ))
        XCTAssertFalse(UserProfile.isVerifiedBadgeActive(
            isVerified: true,
            until: "2026-06-16T00:00:00Z",
            now: now
        ))
        XCTAssertFalse(UserProfile.isVerifiedBadgeActive(
            isVerified: false,
            until: "2026-08-16T00:00:00Z",
            now: now
        ))

        let active = makeSpecialist(
            plan: "free",
            isVerified: true,
            verifiedUntil: "2026-08-16T00:00:00Z"
        )
        let expired = makeSpecialist(
            plan: "free",
            isVerified: true,
            verifiedUntil: "2026-06-16T00:00:00Z"
        )
        XCTAssertTrue(active.hasActiveVerifiedBadge(at: now))
        XCTAssertFalse(expired.hasActiveVerifiedBadge(at: now))
    }

    private func makeProfile(plan: String, endDate: String?) -> UserProfile {
        UserProfile(
            id: "entitlement-test-user",
            name: nil,
            nickname: nil,
            email: nil,
            avatar: nil,
            bio: nil,
            services: nil,
            plan: plan,
            credits: 0,
            purchasedCourseIds: nil,
            purchasedLessonIds: nil,
            subscriptionType: nil,
            subscriptionDate: nil,
            subscriptionEndDate: endDate,
            socialLinks: nil,
            userRole: nil,
            specialistCategory: nil,
            showInHub: nil,
            isPublic: nil,
            signupNumber: nil,
            language: nil,
            lastSeen: nil,
            isVerified: nil,
            verifiedUntil: nil
        )
    }

    private func makeSpecialist(
        plan: String,
        isVerified: Bool? = nil,
        verifiedUntil: String? = nil
    ) -> HubSpecialist {
        HubSpecialist(
            id: "hub-entitlement-test-user",
            name: nil,
            nickname: nil,
            avatar: nil,
            bio: nil,
            specialistCategory: nil,
            plan: plan,
            services: nil,
            socialLinks: nil,
            countryCode: nil,
            city: nil,
            isVerified: isVerified,
            verifiedUntil: verifiedUntil
        )
    }
}
