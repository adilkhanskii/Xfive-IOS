from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ContentProfileRoutingSourceTests(unittest.TestCase):
    def test_profile_gate_is_recoverable_and_never_routes_cross_user_cache(self):
        source = (ROOT / "X5" / "ContentView.swift").read_text(encoding="utf-8")

        self.assertIn("@State private var profileRoutingError", source)
        self.assertIn("guard let token = await auth.freshAccessToken() else", source)
        self.assertIn("let loaded = await currentUser.load", source)
        self.assertIn("guard loaded,", source)
        self.assertIn("profile.id.caseInsensitiveCompare(uid) == .orderedSame", source)
        self.assertIn('Button("Повторить")', source)
        self.assertIn('Button("Выйти")', source)

    def test_ignored_duplicate_profile_insert_refetches_once_without_recursion(self):
        source = (ROOT / "X5" / "Services" / "UserProfile.swift").read_text(
            encoding="utf-8"
        )
        ensure_start = source.index("    private func ensureProfile(")
        ensure_end = source.index("    private func refetchProfileAfterIgnoredInsert(")
        ensure = source[ensure_start:ensure_end]

        self.assertIn("resolution=ignore-duplicates", ensure)
        self.assertIn("refetchProfileAfterIgnoredInsert", ensure)
        self.assertNotIn("return await ensureProfile", ensure)
        self.assertIn('URLQueryItem(name: "limit", value: "1")', source)


if __name__ == "__main__":
    unittest.main()
