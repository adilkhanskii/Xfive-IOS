from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ProfileFollowAndOnboardingSourceTests(unittest.TestCase):
    def test_own_profile_uses_server_follow_counts_instead_of_literal_zeroes(self):
        source = (ROOT / "X5/Views/ProfileView.swift").read_text(encoding="utf-8")

        self.assertIn("@State private var followCounts: ProfileFollowCounts?", source)
        self.assertIn("followCounts?.followers", source)
        self.assertIn("followCounts?.following", source)
        self.assertIn("await refreshFollowCounts()", source)
        self.assertNotIn(
            'StatBubble(value: "0", label: loc.t("profile_followers"))',
            source,
        )
        self.assertNotIn(
            'StatBubble(value: "0", label: loc.t("profile_following"))',
            source,
        )

    def test_own_and_public_profiles_share_one_follow_count_service(self):
        own = (ROOT / "X5/Views/ProfileView.swift").read_text(encoding="utf-8")
        public = (ROOT / "X5/Views/Hub/UserProfileView.swift").read_text(
            encoding="utf-8"
        )
        service = (ROOT / "X5/Services/ProfileFollowService.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("ProfileFollowService", own)
        self.assertIn("ProfileFollowService", public)
        self.assertIn('case followers = "following_id"', service)
        self.assertIn('case following = "follower_id"', service)
        self.assertIn('request.setValue("count=exact"', service)
        self.assertNotIn("private func countFollowers(", public)

    def test_follow_changes_refresh_own_and_public_profile_stats(self):
        own = (ROOT / "X5/Views/ProfileView.swift").read_text(encoding="utf-8")
        public = (ROOT / "X5/Views/Hub/UserProfileView.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn(".x5FollowStateDidChange", own)
        self.assertIn(".x5FollowStateDidChange", public)
        self.assertIn(
            "NotificationCenter.default.post(name: .x5FollowStateDidChange",
            public,
        )

    def test_follow_counters_open_people_lists_on_own_and_public_profiles(self):
        # Просьба Адильхана 07.10: счётчики «Подписчики/Подписки» открывают
        # список людей, а строка ведёт в публичный профиль.
        own = (ROOT / "X5/Views/ProfileView.swift").read_text(encoding="utf-8")
        public = (ROOT / "X5/Views/Hub/UserProfileView.swift").read_text(
            encoding="utf-8"
        )
        screen = (ROOT / "X5/Views/Hub/ProfileFollowListView.swift").read_text(
            encoding="utf-8"
        )
        service = (ROOT / "X5/Services/ProfileFollowService.swift").read_text(
            encoding="utf-8"
        )
        hub = (ROOT / "X5/Views/Hub/HubView.swift").read_text(encoding="utf-8")

        self.assertIn("followListLink(.followers)", own)
        self.assertIn("followListLink(.following)", own)
        self.assertIn("ProfileFollowListView(userId: uid, initialKind: kind)", own)
        self.assertIn(
            "ProfileFollowListView(userId: userId, initialKind: .followers)", public
        )
        self.assertIn(
            "ProfileFollowListView(userId: userId, initialKind: .following)", public
        )

        self.assertIn("followService.loadList(", screen)
        self.assertIn("UserProfileView(userId: person.id, fallback: person)", screen)
        self.assertIn("SpecialistRow(person: person)", screen)
        self.assertIn("BlockList.contains", screen)
        self.assertIn("\nstruct SpecialistRow: View {", hub)
        self.assertNotIn("private struct SpecialistRow", hub)

        self.assertIn('case .followers: return "following_id"', service)
        self.assertIn('URLQueryItem(name: "order", value: "created_at.desc,id.desc")', service)

    def test_onboarding_primary_button_has_explicit_readable_states(self):
        source = (ROOT / "X5/Views/OnboardingView.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            ".foregroundStyle(onboardingPrimaryButtonForeground)", source
        )
        self.assertIn(
            "private var onboardingPrimaryButtonForeground: Color", source
        )
        self.assertIn("return .black", source)
        self.assertIn("return .white.opacity(0.72)", source)
        self.assertIn(".tint(onboardingPrimaryButtonTint)", source)


if __name__ == "__main__":
    unittest.main()
