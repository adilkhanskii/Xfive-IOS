import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from scripts.review_test_credentials import credentials, hydrate, cleanup

SYNTHETIC = {"X5_APP_REVIEW_EMAIL": "test@example.invalid", "X5_APP_REVIEW_PASSWORD": "synthetic-value-only"}


class ReviewTestCredentialsTests(unittest.TestCase):
    def test_both_required_and_multiline_refused(self):
        for values in ({}, {"X5_APP_REVIEW_EMAIL": "test@example.invalid"}, {**SYNTHETIC, "X5_APP_REVIEW_PASSWORD": "a\nb"}):
            with self.assertRaises(ValueError):
                credentials(values)

    def test_hydrate_and_cleanup_only_known_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hydrate(root, SYNTHETIC)
            folder = root / ".secrets/review-test"
            self.assertEqual((folder / "demo_password.txt").read_text(), SYNTHETIC["X5_APP_REVIEW_PASSWORD"])
            if os.name != "nt":
                self.assertEqual((folder / "demo_password.txt").stat().st_mode & 0o777, 0o600)
            (folder / "preserve.txt").write_text("unrelated synthetic file")
            cleanup(root)
            self.assertEqual(list(p.name for p in folder.iterdir()), ["preserve.txt"])

    def test_missing_secrets_create_no_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                hydrate(root, {})
            self.assertFalse((root / ".secrets").exists())

    def test_repeated_hydration_cannot_overwrite_existing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hydrate(root, SYNTHETIC)
            with self.assertRaises(FileExistsError):
                hydrate(root, {**SYNTHETIC, "X5_APP_REVIEW_PASSWORD": "changed-synthetic"})
            self.assertEqual((root / ".secrets/review-test/demo_password.txt").read_text(), SYNTHETIC["X5_APP_REVIEW_PASSWORD"])
            cleanup(root)
            self.assertFalse((root / ".secrets/review-test").exists())

    def test_partial_failure_preserves_preexisting_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / ".secrets/review-test"
            folder.mkdir(parents=True)
            (folder / "demo_password.txt").write_text("existing-synthetic")
            with self.assertRaises(FileExistsError):
                hydrate(root, SYNTHETIC)
            self.assertFalse((folder / "demo_user.txt").exists())
            self.assertEqual((folder / "demo_password.txt").read_text(), "existing-synthetic")

    def test_cli_check_outputs_no_values_and_is_fail_closed(self):
        for environ, expected in ((SYNTHETIC, 0), ({}, 1)):
            task_env = {k: v for k, v in os.environ.items() if not k.startswith("X5_APP_REVIEW_")}
            result = subprocess.run([sys.executable, "-m", "scripts.review_test_credentials", "--check"],
                                    env={**task_env, **environ}, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected)
            self.assertEqual(result.stdout, "")
            for value in SYNTHETIC.values():
                self.assertNotIn(value, result.stderr)


if __name__ == "__main__":
    unittest.main()
