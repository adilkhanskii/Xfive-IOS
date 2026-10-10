from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOC = ROOT / "X5" / "Services" / "LocalizationService.swift"
VERIFIED = ROOT / "X5" / "Views" / "VerifiedBadgeView.swift"
HUB = ROOT / "X5" / "Views" / "Hub" / "HubView.swift"
PLAYER = ROOT / "X5" / "Views" / "LessonPlayerView.swift"
SHIELD = ROOT / "X5" / "Views" / "Helpers" / "ScreenCaptureShield.swift"


class VerifiedInfoSourceTests(unittest.TestCase):
    def test_checkmark_screen_says_tasks_come_first(self) -> None:
        # Адильхан 10.10 01:35: с галочкой уведомление о задании приходит сразу, остальным через час.
        loc = LOC.read_text(encoding="utf-8")
        verified = VERIFIED.read_text(encoding="utf-8")

        self.assertEqual(loc.count('"verified_benefit_tasks"'), 3)
        self.assertIn("остальным через час", loc)
        self.assertIn("Списывается автоматически каждый месяц", loc)
        self.assertLess(
            verified.index('loc.t("verified_benefit_tasks")'),
            verified.index('loc.t("verified_benefit_1")'),
        )

    def test_hub_lists_verified_specialists_first(self) -> None:
        hub = HUB.read_text(encoding="utf-8")
        visible = hub[hub.index("private var visibleSpecialists"):hub.index("private func specialists(matching")]

        self.assertIn("hasActiveVerifiedBadge(at: now)", visible)


class CourseScreenCaptureSourceTests(unittest.TestCase):
    def test_course_video_hides_while_screen_is_recorded(self) -> None:
        # Адильхан 10.10 01:33: «в курсапе не должен работать запись экрана».
        shield = SHIELD.read_text(encoding="utf-8")
        player = PLAYER.read_text(encoding="utf-8")

        self.assertIn("UIScreen.capturedDidChangeNotification", shield)
        self.assertIn("isCaptured", shield)
        self.assertEqual(player.count(".courseScreenCaptureShield { playback.pause() }"), 2)
        self.assertEqual(player.count("if !ScreenCapture.isActive { playback.play() }"), 2)


if __name__ == "__main__":
    unittest.main()
