from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEWS = ROOT / "X5" / "Views"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AdilkhanEdits20261010NightSourceTests(unittest.TestCase):
    """Диас 19:25 «нормально сделай»: правка комментария на месте, все галереи через UIKit, значки Hub."""

    def test_comment_edit_is_in_place_after_migration(self):
        migration = read(ROOT / "supabase" / "migrations" / "20261010190000_portfolio_comment_edit_own.sql")
        self.assertIn("add column if not exists edited_at timestamptz", migration)
        self.assertIn('create policy "owner_update_comment"', migration)
        self.assertIn("new.user_id := old.user_id;", migration)
        self.assertIn("new.edited_at := now();", migration)

        service = read(ROOT / "X5" / "Services" / "PortfolioService.swift")
        edit = service.split("func editComment(", 1)[1].split("func delete(itemId:", 1)[0]
        self.assertIn('request.httpMethod = "PATCH"', edit)
        self.assertNotIn("addComment(", edit)
        self.assertIn('case editedAt = "edited_at"', service)
        self.assertIn('URLQueryItem(name: "select", value: "*")', service)

        portfolio = read(VIEWS / "PortfolioView.swift")
        self.assertIn("comments[index] = updated", portfolio)
        self.assertIn('Text("изменено")', portfolio)

    def test_no_swiftui_photo_pickers_left_outside_chat(self):
        for path in (ROOT / "X5").rglob("*.swift"):
            if path.name in ("ChatThreadView.swift", "PickedPhotoLoader.swift"):
                continue
            source = read(path)
            self.assertNotIn("PhotosPicker(", source, path.name)
            self.assertNotIn(".photosPicker(", source, path.name)
            self.assertNotIn("PhotosPickerItem", source, path.name)
        self.assertIn(".x5SinglePhotoPicker(isPresented: $showingAvatarPicker)", read(VIEWS / "ProfileView.swift"))
        self.assertIn(".x5SinglePhotoPicker(isPresented: $showingStartImagePicker)", read(VIEWS / "Home" / "VideoGeneratorView.swift"))
        self.assertIn(".x5SinglePhotoPicker(isPresented: $showingReferencePicker)", read(VIEWS / "Home" / "AIInfluencerView.swift"))
        self.assertIn("filter: .any(of: [.images, .videos])", read(VIEWS / "PortfolioView.swift"))

    def test_hub_icons_are_checked_and_long_words_shrink(self):
        hub = read(ROOT / "X5" / "Services" / "HubService.swift")
        self.assertIn('return UIImage(systemName: name) != nil ? name : "square.grid.2x2.fill"', hub)
        tests = read(ROOT / "X5Tests" / "HubCategorySymbolTests.swift")
        self.assertIn("for category in HubCategories.all", tests)
        tile = read(VIEWS / "Hub" / "HubView.swift").split("private struct CategoryTile: View", 1)[1]
        self.assertIn(".font(.system(size: titleFontSize, weight: .heavy))", tile)


if __name__ == "__main__":
    unittest.main()
