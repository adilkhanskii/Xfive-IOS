import Foundation

/// Centralizes course ownership rules so subscription state cannot
/// accidentally be treated as ownership of an independently priced course.
enum CourseAccessPolicy {
    static func hasFullAccess(to course: Course, profile: UserProfile?) -> Bool {
        if course.isFree == true { return true }
        if (course.price ?? 0) <= 0 { return true }
        if let authorId = course.authorId,
           profile?.id.caseInsensitiveCompare(authorId) == .orderedSame {
            return true
        }

        return profile?.purchasedCourseIds?.contains(course.id) == true
    }

    /// Key the server writes into `purchased_lesson_ids` for a single paid
    /// lesson. Only `purchase_lesson` can produce it: a database trigger throws
    /// away any entitlement array a client tries to set, and the RPC itself
    /// refuses previews, unpriced lessons and lessons not marked
    /// `sellSeparately`. So the key's presence is proof the lesson was bought.
    static func lessonEntitlementKey(courseId: String, lessonId: String) -> String {
        "\(courseId):\(lessonId)"
    }

    /// True when this lesson alone may be sold, independently of the course.
    static func isSoldSeparately(_ lesson: CourseLesson) -> Bool {
        guard lesson.sellSeparately == true, !lesson.freePreview else { return false }
        return (lesson.price ?? 0) > 0
    }

    static func hasPurchasedLesson(
        _ lesson: CourseLesson,
        in course: Course,
        profile: UserProfile?
    ) -> Bool {
        let key = lessonEntitlementKey(courseId: course.id, lessonId: lesson.id)
        return profile?.purchasedLessonIds?.contains(key) == true
    }

    /// Автор курса или тот, кто купил курс целиком: открыто всё, включая уроки «отдельно».
    static func ownsWholeCourse(_ course: Course, profile: UserProfile?) -> Bool {
        if let authorId = course.authorId,
           profile?.id.caseInsensitiveCompare(authorId) == .orderedSame {
            return true
        }
        if Roles.isDeveloper(email: nil, userId: profile?.id) { return true }
        return profile?.purchasedCourseIds?.contains(course.id) == true
    }

    /// Те же правила, что на сервере (course_video_playback_grant, миграция 20261009200000):
    /// урок, который автор продаёт отдельно, закрыт даже в бесплатном курсе.
    /// Было: «курс за 0 = открыто всё» — платный урок в бесплатном курсе открывался всем (Адильхан 09.10).
    static func canAccess(
        lesson: CourseLesson,
        in course: Course,
        profile: UserProfile?
    ) -> Bool {
        if ownsWholeCourse(course, profile: profile) { return true }
        if lesson.freePreview { return true }
        if isSoldSeparately(lesson) {
            return hasPurchasedLesson(lesson, in: course, profile: profile)
        }
        if hasFullAccess(to: course, profile: profile) { return true }
        return hasPurchasedLesson(lesson, in: course, profile: profile)
    }
}
