import XCTest
@testable import X5

final class CourseAccessPolicyTests: XCTestCase {
    func testFreeCourseHasFullAccess() {
        let course = makeCourse(id: "course-free", price: 50_000, isFree: true)

        XCTAssertTrue(CourseAccessPolicy.hasFullAccess(to: course, profile: makeProfile()))
    }

    func testZeroPriceCourseHasFullAccess() {
        let course = makeCourse(id: "course-zero", price: 0, isFree: false)

        XCTAssertTrue(CourseAccessPolicy.hasFullAccess(to: course, profile: makeProfile()))
    }

    func testMissingPriceUsesSameFreeSemanticsAsServer() {
        let course = makeCourse(id: "course-nil-price", price: nil, isFree: false)

        XCTAssertTrue(CourseAccessPolicy.hasFullAccess(to: course, profile: makeProfile()))
    }

    func testPurchasedCourseIdHasFullAccess() {
        let course = makeCourse(id: "course-paid", price: 50_000, isFree: false)
        let profile = makeProfile(purchasedCourseIds: ["course-paid"])

        XCTAssertTrue(CourseAccessPolicy.hasFullAccess(to: course, profile: profile))
    }

    func testProPlanAloneDoesNotUnlockPaidCourse() {
        let course = makeCourse(id: "course-paid", price: 50_000, isFree: false)
        let profile = makeProfile(plan: "pro")

        XCTAssertFalse(CourseAccessPolicy.hasFullAccess(to: course, profile: profile))
    }

    func testCourseAuthorHasFullAccess() {
        let course = makeCourse(
            id: "course-paid",
            price: 50_000,
            isFree: false,
            authorId: "user-1"
        )

        XCTAssertTrue(CourseAccessPolicy.hasFullAccess(to: course, profile: makeProfile()))
    }

    /// `purchase_lesson` is the only writer of `purchased_lesson_ids` — a
    /// database trigger discards any array a client tries to set — so the key
    /// is proof of a server-priced purchase and must open exactly that lesson.
    func testPurchasedLessonUnlocksOnlyThatLesson() {
        let course = makeCourse(id: "course-paid", price: 50_000, isFree: false)
        let paidLesson = makeSellableLesson(id: "lesson-paid")
        let otherLesson = makeSellableLesson(id: "lesson-other")
        let profile = makeProfile(purchasedLessonIds: ["course-paid:lesson-paid"])

        XCTAssertTrue(CourseAccessPolicy.canAccess(lesson: paidLesson, in: course, profile: profile))
        XCTAssertFalse(CourseAccessPolicy.canAccess(lesson: otherLesson, in: course, profile: profile))
        XCTAssertFalse(CourseAccessPolicy.hasFullAccess(to: course, profile: profile))
    }

    /// Адильхан 09.10: урок за 1000 в курсе с ценой 0 открывался любому аккаунту.
    /// Правило как на сервере: бесплатный курс открывает только НЕплатные уроки.
    func testSeparatelySoldLessonStaysLockedInFreeCourse() {
        let course = makeCourse(id: "course-zero", price: 0, isFree: false, authorId: "author-1")
        let paidLesson = makeSellableLesson(id: "lesson-paid")
        let regularLesson = makeSellableLesson(id: "lesson-regular", sellSeparately: false)

        XCTAssertFalse(CourseAccessPolicy.canAccess(lesson: paidLesson, in: course, profile: makeProfile()))
        XCTAssertTrue(CourseAccessPolicy.canAccess(lesson: regularLesson, in: course, profile: makeProfile()))

        let buyer = makeProfile(purchasedLessonIds: ["course-zero:lesson-paid"])
        XCTAssertTrue(CourseAccessPolicy.canAccess(lesson: paidLesson, in: course, profile: buyer))
    }

    func testAuthorOpensSeparatelySoldLessonInFreeCourse() {
        let course = makeCourse(id: "course-zero", price: 0, isFree: true, authorId: "user-1")

        XCTAssertTrue(CourseAccessPolicy.canAccess(
            lesson: makeSellableLesson(id: "lesson-paid"),
            in: course,
            profile: makeProfile()
        ))
    }

    func testLessonEntitlementIsScopedToItsOwnCourse() {
        let course = makeCourse(id: "course-paid", price: 50_000, isFree: false)
        let lesson = makeSellableLesson(id: "lesson-paid")
        let profile = makeProfile(purchasedLessonIds: ["course-other:lesson-paid"])

        XCTAssertFalse(CourseAccessPolicy.canAccess(lesson: lesson, in: course, profile: profile))
    }

    func testOnlyPricedSeparatelySoldLessonsAreOfferedAlone() {
        XCTAssertTrue(CourseAccessPolicy.isSoldSeparately(makeSellableLesson(id: "lesson-paid")))
        XCTAssertFalse(
            CourseAccessPolicy.isSoldSeparately(makeSellableLesson(id: "lesson-zero", price: 0))
        )
        XCTAssertFalse(
            CourseAccessPolicy.isSoldSeparately(
                makeSellableLesson(id: "lesson-bundled", sellSeparately: false)
            )
        )
        XCTAssertFalse(
            CourseAccessPolicy.isSoldSeparately(
                makeSellableLesson(id: "lesson-preview", isFreePreview: true)
            )
        )
    }

    private func makeSellableLesson(
        id: String,
        price: Int? = 1,
        isFreePreview: Bool = false,
        sellSeparately: Bool = true
    ) -> CourseLesson {
        CourseLesson(
            id: id,
            title: "Paid",
            duration: nil,
            order: 1,
            price: price,
            videoUrl: nil,
            youtubeUrl: nil,
            thumbnailUrl: nil,
            isFreePreview: isFreePreview,
            sellSeparately: sellSeparately
        )
    }

    func testFreePreviewLessonIsAccessibleWhenCourseIsLocked() {
        let course = makeCourse(id: "course-paid", price: 50_000, isFree: false)
        let lesson = CourseLesson(
            id: "lesson-preview",
            title: "Preview",
            duration: nil,
            order: 1,
            price: nil,
            videoUrl: nil,
            youtubeUrl: nil,
            thumbnailUrl: nil,
            isFreePreview: true,
            sellSeparately: false
        )

        XCTAssertTrue(
            CourseAccessPolicy.canAccess(
                lesson: lesson,
                in: course,
                profile: makeProfile()
            )
        )
    }

    private func makeCourse(
        id: String,
        price: Int?,
        isFree: Bool,
        authorId: String? = nil
    ) -> Course {
        Course(
            id: id,
            title: "Course",
            description: nil,
            marketingHook: nil,
            coverUrl: nil,
            authorName: "DOPAMINE",
            authorId: authorId,
            price: price,
            isFree: isFree,
            isPublic: true,
            courseLanguage: "ru",
            averageRating: nil,
            studentsCount: nil,
            sortOrder: nil,
            categoriesRaw: []
        )
    }

    private func makeProfile(
        plan: String = "free",
        purchasedCourseIds: [String] = [],
        purchasedLessonIds: [String]? = nil
    ) -> UserProfile {
        UserProfile(
            id: "user-1",
            name: nil,
            nickname: nil,
            email: nil,
            avatar: nil,
            bio: nil,
            services: nil,
            plan: plan,
            credits: 100_000,
            purchasedCourseIds: purchasedCourseIds,
            purchasedLessonIds: purchasedLessonIds,
            subscriptionType: nil,
            subscriptionDate: nil,
            subscriptionEndDate: nil,
            socialLinks: nil,
            userRole: nil,
            specialistCategory: nil,
            showInHub: nil,
            isPublic: true,
            signupNumber: nil,
            language: "ru",
            lastSeen: nil,
            isVerified: nil,
            verifiedUntil: nil
        )
    }
}
