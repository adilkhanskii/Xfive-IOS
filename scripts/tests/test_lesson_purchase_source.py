from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "X5" / "Models" / "CourseAccessPolicy.swift"
SERVICE = ROOT / "X5" / "Services" / "CoursePurchaseService.swift"
PROFILE = ROOT / "X5" / "Services" / "UserProfile.swift"
COURSES_VIEW = ROOT / "X5" / "Views" / "CoursesView.swift"
EDITOR = ROOT / "X5" / "Views" / "CourseEditorView.swift"


class LessonPurchaseSourceTests(unittest.TestCase):
    def test_single_lesson_access_follows_the_server_entitlement(self):
        policy = POLICY.read_text(encoding="utf-8")

        self.assertIn('"\\(courseId):\\(lessonId)"', policy)
        self.assertIn("static func isSoldSeparately(_ lesson: CourseLesson) -> Bool", policy)
        self.assertIn("profile?.purchasedLessonIds?.contains(key) == true", policy)
        # A preview or unpriced lesson is never sellable on its own.
        self.assertIn(
            "guard lesson.sellSeparately == true, !lesson.freePreview else { return false }",
            policy,
        )
        self.assertIn("return (lesson.price ?? 0) > 0", policy)

    def test_client_never_invents_the_price_or_the_entitlement_key(self):
        service = SERVICE.read_text(encoding="utf-8")
        profile = PROFILE.read_text(encoding="utf-8")

        self.assertIn('rest/v1/rpc/\\(rpc)', service)
        self.assertIn('named: "purchase_lesson"', service)
        self.assertIn('case pExpectedPrice = "p_expected_price"', service)
        self.assertIn('case lessonKey = "lesson_key"', service)

        # Ownership requires the key the server said it stored.
        self.assertIn("guard status == .purchased || status == .alreadyOwned else { return false }", service)
        self.assertIn("return !lessonKey.isEmpty", service)
        self.assertIn(
            "func applyLessonPurchase(_ response: LessonPurchaseResponse, for context: ProfileOperationContext?)",
            profile,
        )
        # Same account/epoch fence as course purchases: a late response never
        # lands on another signed-in user's profile.
        self.assertIn(
            "guard isCurrent(context), var profile, profile.id.lowercased() == context?.userID else { return }",
            profile,
        )
        self.assertIn("purchased.append(response.lessonKey)", profile)

    def test_lesson_purchase_is_fenced_by_the_profile_operation(self):
        view = COURSES_VIEW.read_text(encoding="utf-8")
        lesson_flow = view.split("private func completeLessonPurchase(_ lesson: CourseLesson) async {", 1)[1]
        lesson_flow = lesson_flow.split("private var sortedCategories", 1)[0]

        self.assertIn("guard let profileOperation = currentUser.operationContext() else { return }", lesson_flow)
        self.assertIn("await currentUser.accessTokenForOperation(profileOperation, refresh: {", lesson_flow)
        self.assertIn("guard currentUser.isCurrent(profileOperation) else { return }", lesson_flow)
        self.assertIn("currentUser.applyLessonPurchase(response, for: profileOperation)", lesson_flow)
        self.assertNotIn("currentUser.applyLessonPurchase(response)\n", lesson_flow)

    def test_locked_sellable_lesson_offers_itself_before_the_whole_course(self):
        view = COURSES_VIEW.read_text(encoding="utf-8")

        # 09.10: покупка урока — доступ на 30 дней (Адильхан).
        self.assertIn('"Разблокировать урок на 30 дней?"', view)
        self.assertIn("await completeLessonPurchase(lesson)", view)
        self.assertIn("private func separatePrice(for lesson: CourseLesson) -> Int?", view)
        self.assertIn("if let lesson, separatePrice(for: lesson) != nil {", view)
        # A price the server corrected must be reconfirmed, never auto-charged.
        self.assertIn("serverConfirmedLessonPrices[lesson.id] = latestPrice", view)
        self.assertIn("case .lessonUnavailable:", view)

    def test_author_can_mark_a_lesson_as_sold_separately(self):
        editor = EDITOR.read_text(encoding="utf-8")

        self.assertIn('Toggle("Продавать отдельно", isOn: $sellSeparately)', editor)
        self.assertIn('Text("Цена урока")', editor)
        self.assertNotIn(
            'Text("Доступ к уроку задаётся покупкой всего курса или флагом бесплатного preview.")\n'
            "                        .font(.footnote)",
            editor,
        )


if __name__ == "__main__":
    unittest.main()
