from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class VerifiedBadgeSourceTests(unittest.TestCase):
    def test_hub_surfaces_use_expiry_aware_badge_state(self):
        hub = (ROOT / "X5" / "Views" / "Hub" / "HubView.swift").read_text(
            encoding="utf-8"
        )
        profile = (
            ROOT / "X5" / "Views" / "Hub" / "UserProfileView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("person.hasActiveVerifiedBadge", hub)
        self.assertNotIn("person.isVerified == true", hub)
        self.assertIn("fallback?.hasActiveVerifiedBadge", profile)
        self.assertNotIn("fallback?.isVerified == true", profile)


if __name__ == "__main__":
    unittest.main()
