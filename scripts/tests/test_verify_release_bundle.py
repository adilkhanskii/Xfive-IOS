import io
import plistlib
import unittest
from zipfile import ZipFile
from scripts.verify_release_bundle import verify


def ipa(*extra_files, build="240"):
    output = io.BytesIO()
    with ZipFile(output, "w") as archive:
        archive.writestr("Payload/Xfive marketing.app/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "com.x5studio.app",
            "CFBundleDisplayName": "Xfive marketing",
            "CFBundleShortVersionString": "1.1.9", "CFBundleVersion": build,
        }))
        for name in extra_files:
            archive.writestr(name, "synthetic")
    output.seek(0)
    return output


class ReleaseBundleTests(unittest.TestCase):
    def test_valid_application(self):
        self.assertEqual(verify(ipa(), "1.1.9", "240")["test_resources"], 0)

    def test_wrong_build_rejected(self):
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            verify(ipa(build="239"), "1.1.9", "240")

    def test_review_credentials_rejected(self):
        for name in ("demo_user.txt", "demo_password.txt"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Test-only"):
                verify(ipa(f"Payload/Xfive marketing.app/{name}"), "1.1.9", "240")

    def test_test_runner_rejected(self):
        with self.assertRaisesRegex(ValueError, "Test-only"):
            verify(ipa("Payload/Xfive marketing.app/PlugIns/X5Tests.xctest/Info.plist"), "1.1.9", "240")
