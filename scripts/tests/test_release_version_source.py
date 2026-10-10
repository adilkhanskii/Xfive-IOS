from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseVersionSourceTests(unittest.TestCase):
    def test_app_store_replacement_is_manual_only_for_testflight_builds(self):
        workflows = (
            "asc-release-prepare.yml",
            "asc-release-submit.yml",
            "asc-release-replace-submit.yml",
        )
        for name in workflows:
            with self.subTest(workflow=name):
                workflow = (
                    ROOT / ".github" / "workflows" / name
                ).read_text(encoding="utf-8")
                trigger_block = workflow.split("jobs:", 1)[0]

                self.assertIn("workflow_dispatch:", trigger_block)
                self.assertNotIn(
                    "\n  push:",
                    trigger_block,
                    "A TestFlight source push must never alter App Store review.",
                )

    def test_testflight_runtime_advances_without_arming_app_store_submission(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        fastfile = (ROOT / "fastlane" / "Fastfile").read_text(encoding="utf-8")
        review_notes = (
            ROOT / "fastlane" / "metadata" / "review_information" / "notes.txt"
        ).read_text(encoding="utf-8")
        submit_workflow = (
            ROOT / ".github" / "workflows" / "asc-release-submit.yml"
        ).read_text(encoding="utf-8")
        prepare_workflow = (
            ROOT / ".github" / "workflows" / "asc-release-prepare.yml"
        ).read_text(encoding="utf-8")

        marketing_version = re.search(
            r'MARKETING_VERSION:\s*"([^"]+)"', project
        ).group(1)
        runtime_build_number = re.search(
            r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project
        ).group(1)
        fastlane_version = re.search(
            r'APP_VERSION\s*=\s*"([^"]+)"', fastfile
        ).group(1)

        self.assertEqual(marketing_version, "1.1.12")
        # 09.10.2026: в App Store живая 1.1.10; ревью идёт как 1.1.12 сборка 251 из release/ios.
        # Сборка в TestFlight и цель ревью снова один и тот же номер.
        # 07.10.2026: тестовые TestFlight-сборки ушли вперёд (245 — фикс модуля
        # курса + чат + город в профиле; 246 — то же + Bunny Stream для видео
        # уроков, одна общая сборка; 247 — фикс двойной галереи обложки урока;
        # 08.10: 248 — ползунок голосовых + порядок курсов; 249 — то же +
        # перетаскивание карточек курсов в каталоге);
        # 09.10 вечер: TestFlight 252 (вторая пачка правок Адильхана); App Store-ревью пока остаётся на 251.
        # 10.10: TestFlight 253 (галочка: задания первым; запрет записи экрана в курсах).
        # 10.10 вечером: TestFlight 257 (обложка видео меняется, галерея на корне экрана, размеры Nano Banana, без поиска).
        self.assertEqual(runtime_build_number, "257")
        self.assertEqual(fastlane_version, marketing_version)
        self.assertIn(
            f"Version {marketing_version} build 257",
            review_notes,
        )
        self.assertIn(
            f'EXPECTED_VERSION: "{marketing_version}"',
            submit_workflow,
        )
        self.assertIn(
            'EXPECTED_BUILD: "257"',
            submit_workflow,
        )
        self.assertIn(
            f'VERSION: "{marketing_version}"',
            prepare_workflow,
        )
        self.assertIn(
            'BUILD_NUMBER: "257"',
            prepare_workflow,
        )

    def test_app_store_review_notes_fit_apple_limit(self):
        notes = (
            ROOT / "fastlane" / "metadata" / "review_information" / "notes.txt"
        ).read_bytes()

        self.assertLessEqual(len(notes), 4000)

    def test_store_metadata_discloses_portfolio_moderation_provider(self):
        description = (
            ROOT / "fastlane" / "metadata" / "en-US" / "description.txt"
        ).read_text(encoding="utf-8")
        notes = (
            ROOT / "fastlane" / "metadata" / "review_information" / "notes.txt"
        ).read_text(encoding="utf-8")
        privacy = (ROOT / "site" / "privacy.html").read_text(encoding="utf-8")

        self.assertIn("OpenAI", description)
        self.assertIn("OpenAI", notes)
        self.assertIn("OpenAI", privacy)
        self.assertIn("portfolio", description.lower())
        self.assertIn("moderation", description.lower())

    def test_submission_declares_user_generated_third_party_content(self):
        fastfile = (ROOT / "fastlane" / "Fastfile").read_text(encoding="utf-8")

        self.assertIn(
            "content_rights_contains_third_party_content: true",
            fastfile,
        )
        self.assertIn("content_rights_has_rights: true", fastfile)


if __name__ == "__main__":
    unittest.main()
