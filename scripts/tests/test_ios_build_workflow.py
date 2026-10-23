from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IOSBuildWorkflowTests(unittest.TestCase):
    def test_archive_workflow_uses_a_shared_generated_scheme(self):
        workflow = (ROOT / ".github" / "workflows" / "ios-build.yml").read_text(
            encoding="utf-8"
        )
        project = (ROOT / "project.yml").read_text(encoding="utf-8")

        scheme_match = re.search(
            r"^\s+SCHEME:\s*([^\s#]+)\s*$", workflow, re.MULTILINE
        )
        self.assertIsNotNone(scheme_match, "ios-build.yml must declare SCHEME")
        scheme = scheme_match.group(1).strip('"\'')

        schemes = project.split("\nschemes:\n", maxsplit=1)
        self.assertEqual(len(schemes), 2, "project.yml must define shared schemes")
        self.assertRegex(
            schemes[1],
            rf"(?m)^\s{{2}}{re.escape(scheme)}:\s*$",
            f"Archive scheme {scheme!r} is not generated as a shared scheme in project.yml",
        )

    def test_signed_ipa_is_not_published_as_a_github_artifact(self):
        workflow = (ROOT / ".github" / "workflows" / "ios-build.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("actions/upload-artifact", workflow)
        self.assertNotIn("Upload IPA artifact", workflow)
        self.assertNotRegex(workflow, r"path:\s*.*\.ipa")
        self.assertIn("xcrun altool --upload-app", workflow)


if __name__ == "__main__":
    unittest.main()
