import pathlib
import re
import unittest


WORKFLOW = (
    pathlib.Path(__file__).parents[2]
    / ".github"
    / "workflows"
    / "asc-release-audit.yml"
).read_text(encoding="utf-8")


class AppStoreReleaseAuditContractTests(unittest.TestCase):
    def test_internal_candidate_does_not_retarget_pending_review(self):
        self.assertIn('EXPECTED_BUILD: "251"', WORKFLOW)
        self.assertIn('EXPECTED_RUNTIME_BUILD: "251"', WORKFLOW)
        self.assertIn('build.group(1) != os.environ["EXPECTED_RUNTIME_BUILD"]', WORKFLOW)

    def test_exact_app_name_is_a_live_audit_invariant(self):
        self.assertIn('EXPECTED_APP_NAME: "Xfive marketing"', WORKFLOW)
        self.assertIn("/appInfos/{app_info['id']}/appInfoLocalizations", WORKFLOW)
        self.assertIn('localized_names.get("en-US", set())', WORKFLOW)

    def test_live_app_store_version_is_a_success_state(self):
        match = re.search(
            r"READY_VERSION_STATES\s*=\s*\{(?P<body>.*?)\n\s*\}",
            WORKFLOW,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertIn('"READY_FOR_SALE"', match.group("body"))


if __name__ == "__main__":
    unittest.main()
