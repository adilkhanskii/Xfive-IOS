from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReviewSecretBoundaryTests(unittest.TestCase):
    def test_no_plaintext_review_login_in_source(self):
        for name in ("demo_user.txt", "demo_password.txt"):
            self.assertFalse((ROOT / "fastlane/metadata/review_information" / name).exists())

    def test_acceptance_uses_ephemeral_optional_resources(self):
        project = (ROOT / "project.yml").read_text()
        self.assertNotIn("path: fastlane/metadata/review_information/demo_", project)
        for name in ("demo_user", "demo_password"):
            self.assertRegex(project, rf"path: \.secrets/review-test/{name}\.txt\n\s+optional: true\n\s+buildPhase: resources")

    def test_public_ci_cannot_upload_authenticated_screens(self):
        source = (ROOT / ".github/workflows/ios-course-ci.yml").read_text()
        acceptance = source.split("  acceptance-simulator:")[1].split("\n  test:")[0]
        self.assertIn("environment: app-store-production", acceptance)
        self.assertIn("secrets.X5_APP_REVIEW_PASSWORD", acceptance)
        upload = acceptance.split("- uses: actions/upload-artifact@")[1].split("- name:")[0]
        self.assertIn("if: always() && github.event.repository.private == true", upload)
        self.assertIn("scripts/review_test_credentials.py --cleanup", acceptance)

    def test_all_metadata_workflows_fail_before_apple_changes_if_secret_missing(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            source = path.read_text(encoding="utf-8-sig")
            if "bundle exec fastlane" not in source:
                continue
            with self.subTest(path=path.name):
                self.assertIn("secrets.X5_APP_REVIEW_PASSWORD", source)
                self.assertIn("secrets.X5_APP_REVIEW_EMAIL", source)
                guard = source.index("scripts/review_test_credentials.py --check")
                self.assertLess(guard, source.index("bundle exec fastlane"))
                # Required guard precedes every API mutation in these workflows.
                first_api = re.search(r"requests\.(?:post|patch|delete)\(", source)
                if first_api:
                    self.assertLess(guard, first_api.start())

    def test_fastlane_and_local_probe_require_in_memory_secrets(self):
        fastfile = (ROOT / "fastlane/Fastfile").read_text()
        self.assertIn("app_review_information: required_review_credentials", fastfile)
        helper = (ROOT / "fastlane/review_credentials.rb").read_text()
        self.assertIn('ENV["X5_APP_REVIEW_PASSWORD"]', helper)
        self.assertIn('require_relative "review_credentials"', fastfile)
        deliver = (ROOT / "fastlane/Deliverfile").read_text()
        self.assertIn("config.set(:app_review_information, required_review_credentials)", deliver)
        self.assertNotIn("app_review_information required_review_credentials", deliver)
        self.assertIn('ENV["FASTLANE_SKIP_ALL_LANE_SUMMARIES"] = "1"', helper)
        source = (ROOT / "scripts/acceptance_read_only_audit.mjs").read_text()
        self.assertIn("process.env.X5_APP_REVIEW_PASSWORD", source)
        self.assertNotIn('read("fastlane/metadata/review_information/demo_password.txt")', source)


if __name__ == "__main__":
    unittest.main()
