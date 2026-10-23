from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
PYTHON_LOCK = ROOT / ".github" / "requirements" / "asc-requirements.lock"
COURSE_CI = WORKFLOW_DIR / "ios-course-ci.yml"
IOS_BUILD = WORKFLOW_DIR / "ios-build.yml"
FULL_COMMIT = re.compile(r"[0-9a-f]{40}")
CHECKOUT = "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"


def workflow_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def job_blocks(source: str):
    jobs = source.split("\njobs:\n", 1)[1]
    matches = list(re.finditer(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs))
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(jobs)
        yield match.group(1), jobs[match.start():end]


class CISupplyChainSourceTests(unittest.TestCase):
    def test_every_action_is_pinned_to_a_full_commit(self):
        for path in sorted(WORKFLOW_DIR.glob("*.yml")):
            source = workflow_text(path)
            for line in source.splitlines():
                stripped = line.lstrip()
                if not (stripped.startswith("uses:") or stripped.startswith("- uses:")):
                    continue
                reference = line.split("uses:", 1)[1].strip().split("#", 1)[0].strip()
                self.assertIn("@", reference, f"missing action ref in {path.name}: {line}")
                revision = reference.rsplit("@", 1)[1]
                self.assertRegex(
                    revision,
                    FULL_COMMIT,
                    f"mutable action in {path.name}: {reference}",
                )

    def test_every_checkout_is_read_only_and_does_not_persist_credentials(self):
        for path in sorted(WORKFLOW_DIR.glob("*.yml")):
            source = workflow_text(path)
            self.assertNotIn("contents: write", source, path.name)
            self.assertRegex(source, r"(?m)^permissions:\n  contents: read$", path.name)
            for _, block in job_blocks(source):
                if "actions/checkout@" not in block:
                    continue
                self.assertIn(CHECKOUT, block, path.name)
                self.assertIn("persist-credentials: false", block, path.name)
                self.assertNotIn("persist-credentials: true", block, path.name)

    def test_python_installers_use_the_hashed_lock_and_have_a_checkout(self):
        for path in sorted(WORKFLOW_DIR.glob("*.yml")):
            source = workflow_text(path)
            for job_name, block in job_blocks(source):
                if "pip install" not in block:
                    continue
                self.assertIn(CHECKOUT, block, f"{path.name}:{job_name}")
                for line in block.splitlines():
                    if "pip install" in line:
                        self.assertIn(
                            "--require-hashes -r .github/requirements/asc-requirements.lock",
                            line,
                            f"unlocked Python install in {path.name}:{job_name}",
                        )

        lock = PYTHON_LOCK.read_text(encoding="utf-8")
        self.assertIn("pyjwt==2.10.1", lock)
        self.assertIn("requests==2.32.5", lock)
        self.assertGreaterEqual(lock.count("--hash=sha256:"), 20)
        for line in lock.splitlines():
            if line and line[0].isalpha():
                self.assertIn("==", line, f"unversioned dependency: {line}")

    def test_fastlane_is_installed_only_from_the_exact_bundle_lock(self):
        gemfile = (ROOT / "Gemfile").read_text(encoding="utf-8")
        gem_lock = (ROOT / "Gemfile.lock").read_text(encoding="utf-8")
        self.assertIn('gem "fastlane", "2.237.0"', gemfile)
        self.assertIn("fastlane (2.237.0)", gem_lock)
        self.assertIn("fastlane (= 2.237.0)", gem_lock)
        self.assertIn("BUNDLED WITH\n   2.4.22", gem_lock)

        for path in sorted(WORKFLOW_DIR.glob("*.yml")):
            source = workflow_text(path)
            self.assertNotIn("gem install fastlane", source, path.name)
            if "bundle exec fastlane" in source:
                self.assertIn("bundler-cache: true", source, path.name)
                self.assertRegex(source, r"ruby/setup-ruby@[0-9a-f]{40}")
                self.assertIn('ruby-version: "3.3.12"', source, path.name)
            self.assertIsNone(
                re.search(r"(?m)(?<!bundle exec )fastlane ios ", source),
                path.name,
            )

    def test_release_and_privileged_jobs_are_environment_gated(self):
        for path in sorted(WORKFLOW_DIR.glob("asc-*.yml")):
            for job_name, block in job_blocks(workflow_text(path)):
                self.assertIn(
                    "environment: app-store-production",
                    block,
                    f"{path.name}:{job_name}",
                )

        expected = {
            IOS_BUILD: "app-store-production",
            WORKFLOW_DIR / "google-play-voided-reconciliation.yml": "google-play-production",
            WORKFLOW_DIR / "fetch-app-diagnostics.yml": "supabase-production",
        }
        for path, environment in expected.items():
            self.assertIn(f"environment: {environment}", workflow_text(path), path.name)

        course_jobs = dict(job_blocks(workflow_text(COURSE_CI)))
        self.assertNotIn("environment:", course_jobs["test"])
        self.assertIn("environment: app-store-production", course_jobs["apple-sandbox-audit"])
        self.assertIn("environment: app-store-production", course_jobs["apple-sandbox-recovery"])

    def test_xcodegen_downloads_are_exact_and_checksum_verified(self):
        for path in (COURSE_CI, IOS_BUILD):
            source = workflow_text(path)
            self.assertIn("XcodeGen/releases/download/2.45.4/xcodegen.zip", source)
            self.assertIn(
                "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef",
                source,
            )
            self.assertIn("shasum -a 256 -c -", source)
            self.assertNotIn("brew install xcodegen", source)

    def test_private_portfolio_contract_is_an_explicit_course_ci_gate(self):
        source = workflow_text(COURSE_CI)
        required = (
            "supabase/migrations/20260801123000_private_portfolio_media.sql",
            "supabase/tests/portfolio_private_media_contract_test.mjs",
            "-only-testing:X5Tests/PortfolioMediaPrivacyTests",
        )
        for value in required:
            self.assertIn(value, source)


if __name__ == "__main__":
    unittest.main()
