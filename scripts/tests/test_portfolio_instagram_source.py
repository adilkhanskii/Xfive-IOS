from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "X5" / "Services" / "PortfolioService.swift"
PORTFOLIO = ROOT / "X5" / "Views" / "PortfolioView.swift"
PROFILE = ROOT / "X5" / "Views" / "ProfileView.swift"
PUBLIC_PROFILE = ROOT / "X5" / "Views" / "Hub" / "UserProfileView.swift"
MIGRATION = ROOT / "supabase" / "migrations" / "20260815170000_portfolio_saves.sql"


class PortfolioInstagramSourceTests(unittest.TestCase):
    def test_saves_are_server_backed_and_private_to_current_user(self):
        service = SERVICE.read_text(encoding="utf-8")
        migration = MIGRATION.read_text(encoding="utf-8")

        self.assertIn("portfolio_item_saves", service)
        self.assertIn("func loadSaved", service)
        self.assertIn("func saveState", service)
        self.assertIn("func setSaved", service)
        self.assertIn("user_id = (select auth.uid())", migration)
        self.assertIn("enable row level security", migration)
        self.assertIn("revoke all on table public.portfolio_item_saves from anon", migration)

    def test_profile_has_saved_tab_and_saved_grid(self):
        source = PROFILE.read_text(encoding="utf-8")

        self.assertIn("case saved", source)
        self.assertIn('return "Сохранённые"', source)
        self.assertIn("savedWorksSection", source)
        self.assertIn("mode: .saved", source)

    def test_foreign_profile_uses_public_grid_without_edit_controls(self):
        public_profile = PUBLIC_PROFILE.read_text(encoding="utf-8")
        portfolio = PORTFOLIO.read_text(encoding="utf-8")

        self.assertIn("PortfolioGrid(userId: userId, canEdit: false)", public_profile)
        self.assertIn("authorForItem", portfolio)
        self.assertIn("authorHeader", portfolio)
        self.assertIn("onLoadSaved", portfolio)
        self.assertIn("onSetSaved", portfolio)
        self.assertNotIn("isSaved.toggle()", portfolio)

    def test_full_post_supports_video_image_caption_likes_comments_and_saves(self):
        source = PORTFOLIO.read_text(encoding="utf-8")

        self.assertIn("VideoPlayer(player: player)", source)
        self.assertIn("CachedAsyncImage(url: url)", source)
        self.assertIn("captionBlock", source)
        self.assertIn("toggleLike", source)
        self.assertIn("sendComment", source)
        self.assertIn("toggleSaved", source)


if __name__ == "__main__":
    unittest.main()
