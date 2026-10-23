from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEWS = ROOT / "X5" / "Views"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AdilkhanCover20261010Tests(unittest.TestCase):
    """Адильхан 10.10 20:10–20:12 (сборка 255): обложка не меняется, «не пашет», убрать поиск."""

    def test_gallery_is_a_root_sheet_without_a_sticky_static_flag(self):
        loader = read(VIEWS / "Helpers" / "PickedPhotoLoader.swift")
        self.assertNotIn("private static var active", loader)
        self.assertIn("sheet(isPresented: isPresented)", loader)

    def test_cover_picker_lives_on_the_screen_root_not_in_the_form_row(self):
        portfolio = read(VIEWS / "PortfolioView.swift")
        row = portfolio.split("private struct PortfolioCoverPickerRow: View", 1)[1].split("// MARK: - Add item", 1)[0]
        self.assertNotIn("x5SinglePhotoPicker", row)
        self.assertNotIn("x5PhotoPicker", row)
        self.assertIn("pick.showingPicker = true", row)
        # Оба экрана вешают галерею обложки на корень и не дают сохранить, пока фото грузится.
        self.assertEqual(portfolio.count(".x5SinglePhotoPicker(isPresented: $coverPick.showingPicker)"), 2)
        self.assertIn(".disabled(saving || coverPick.loading)", portfolio)
        self.assertIn("coverPick.loading)", portfolio.split("struct AddPortfolioItemView: View", 1)[1])

    def test_no_picker_modifier_inside_form_sections(self):
        # Модификатор галереи не должен стоять внутри Section { … } — только на корне экрана.
        for path in (ROOT / "X5").rglob("*.swift"):
            source = read(path)
            for match in re.finditer(r"Section\s*(\([^)]*\))?\s*\{", source):
                depth, i = 1, match.end()
                while depth and i < len(source):
                    depth += {"{": 1, "}": -1}.get(source[i], 0)
                    i += 1
                body = source[match.end():i]
                self.assertNotIn(".x5SinglePhotoPicker(", body, path.name)
                self.assertNotIn(".x5PhotoPicker(", body, path.name)

    def test_cover_change_has_simulator_tests(self):
        tests = read(ROOT / "X5Tests" / "PortfolioCoverChangeTests.swift")
        self.assertIn("testCoverChangeUploadsNewFileAndPointsItemAtIt", tests)
        self.assertIn("testRecomposePutsNewCoverOnTopAndKeepsVideoFrames", tests)
        self.assertIn("testCoverPickLoadsPickedPhotoAndBlocksSaveWhileLoading", tests)

    def test_locked_sizes_switch_the_model_instead_of_being_dead(self):
        generator = read(VIEWS / "Home" / "ImageGeneratorView.swift")
        self.assertNotIn('systemImage: "lock")', generator)
        self.assertIn("if let model = providerSupporting(size)", generator)
        self.assertIn("selectedProvider = model", generator)

    def test_home_has_no_search_button(self):
        home = read(VIEWS / "Home" / "HomeView.swift")
        self.assertNotIn('Image(systemName: "magnifyingglass")', home)


if __name__ == "__main__":
    unittest.main()
