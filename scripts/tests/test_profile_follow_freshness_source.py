from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
OWN_PROFILE = ROOT / "X5" / "Views" / "ProfileView.swift"
PUBLIC_PROFILE = ROOT / "X5" / "Views" / "Hub" / "UserProfileView.swift"


class ProfileFollowFreshnessSourceTests(unittest.TestCase):
    def test_own_profile_refreshes_counts_on_pull_and_foreground(self):
        source = OWN_PROFILE.read_text(encoding="utf-8")

        self.assertIn(".refreshable { await refreshProfile() }", source)
        self.assertIn("@Environment(\\.scenePhase) private var scenePhase", source)
        self.assertIn(".task(id: scenePhase)", source)
        # 10.10: только после настоящего фона (не после галереи/Face ID).
        self.assertIn("guard scenePhase == .active, wasInBackground else { return }", source)
        self.assertIn("await refreshFollowCounts()", source)

    def test_public_profile_refreshes_counts_on_pull_and_foreground(self):
        source = PUBLIC_PROFILE.read_text(encoding="utf-8")

        self.assertIn(".refreshable { await refreshPublicProfile() }", source)
        self.assertIn("@Environment(\\.scenePhase) private var scenePhase", source)
        self.assertIn(".task(id: scenePhase)", source)
        self.assertIn("guard scenePhase == .active, !isMe else { return }", source)
        self.assertIn("await loadFollowState()", source)


if __name__ == "__main__":
    unittest.main()
