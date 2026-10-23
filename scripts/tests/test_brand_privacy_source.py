from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BrandPrivacySourceTests(unittest.TestCase):
    def test_user_visible_brand_uses_exact_client_name(self):
        visible_files = [
            ROOT / "X5" / "Services" / "LocalizationService.swift",
            ROOT / "X5" / "Views" / "CoursesView.swift",
            ROOT / "X5" / "Views" / "CourseEditorView.swift",
            ROOT / "X5" / "Views" / "SettingsView.swift",
            ROOT / "X5" / "Views" / "Hub" / "HubView.swift",
            ROOT / "X5" / "Views" / "Hub" / "UserProfileView.swift",
            ROOT / "X5" / "Views" / "PortfolioView.swift",
            ROOT / "X5" / "Services" / "UserProfile.swift",
            ROOT / "fastlane" / "metadata" / "en-US" / "description.txt",
            ROOT / "fastlane" / "metadata" / "review_information" / "notes.txt",
            ROOT / "site" / "index.html",
            ROOT / "site" / "privacy.html",
            ROOT / "site" / "support.html",
            ROOT / "site" / "terms.html",
        ]

        for path in visible_files:
            with self.subTest(path=path):
                source = path.read_text(encoding="utf-8")
                self.assertIn("Xfive marketing", source)
                self.assertNotIn("X five marketing", source)

    def test_photo_permissions_cover_course_video_and_ai_media(self):
        expected_read = (
            "Select photos and videos for courses, chats, portfolio, "
            "and AI tools."
        )
        expected_add = "Save generated images and videos to your photo library."

        with (ROOT / "X5" / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(info["NSPhotoLibraryUsageDescription"], expected_read)
        self.assertEqual(
            info["NSPhotoLibraryAddUsageDescription"],
            expected_add,
        )

        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn(f'NSPhotoLibraryUsageDescription: "{expected_read}"', project)
        self.assertIn(
            f'NSPhotoLibraryAddUsageDescription: "{expected_add}"',
            project,
        )

        localized = {
            "en": (
                expected_read,
                expected_add,
            ),
            "ru": (
                "Выбирайте фото и видео для курсов, чатов, портфолио "
                "и AI-инструментов.",
                "Сохраняйте созданные изображения и видео в галерею.",
            ),
            "kk": (
                "Курстар, чаттар, портфолио және AI құралдары үшін "
                "фото мен видеоны таңдаңыз.",
                "Жасалған суреттер мен видеоларды галереяға сақтаңыз.",
            ),
        }
        for language, (read_text, add_text) in localized.items():
            source = (
                ROOT / "X5" / f"{language}.lproj" / "InfoPlist.strings"
            ).read_text(encoding="utf-8")
            self.assertIn(
                f'"NSPhotoLibraryUsageDescription" = "{read_text}";',
                source,
            )
            self.assertIn(
                f'"NSPhotoLibraryAddUsageDescription" = "{add_text}";',
                source,
            )


if __name__ == "__main__":
    unittest.main()
