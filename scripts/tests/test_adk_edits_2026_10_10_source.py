from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEWS = ROOT / "X5" / "Views"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AdilkhanEdits20261010SourceTests(unittest.TestCase):
    """Адильхан 10.10 13:58–14:03: галерея мигает, плитка портфолио, карточки товаров, текст галочки."""

    def test_app_resyncs_only_after_real_background(self):
        # Галерея и Face ID делают приложение «неактивным» — это не повод
        # перезагружать профиль и перерисовывать весь экран.
        app = read(ROOT / "X5" / "X5App.swift")
        self.assertIn("if phase == .background { returnedFromBackground = true }", app)
        self.assertIn("guard phase == .active, returnedFromBackground else { return }", app)

    def test_single_photo_pickers_use_the_uikit_picker(self):
        loader = read(VIEWS / "Helpers" / "PickedPhotoLoader.swift")
        # 10.10 вечером: галерею показывает сам UIKit (см. test_adk_edits_2026_10_10_evening).
        self.assertIn("struct SystemPhotoPicker: UIViewControllerRepresentable", loader)
        self.assertIn("x5PhotoPicker(isPresented: isPresented, limit: 1)", loader)
        self.assertIn("static func loadPrepared(\n        from provider: NSItemProvider", loader)

        portfolio = read(VIEWS / "PortfolioView.swift")
        generator = read(VIEWS / "Home" / "ImageGeneratorView.swift")
        editor = read(VIEWS / "CourseEditorView.swift")
        self.assertIn(".x5SinglePhotoPicker(isPresented: $coverPick.showingPicker)", portfolio)
        self.assertIn(".x5SinglePhotoPicker(isPresented: $showingMainPhotoPicker)", generator)
        self.assertIn(".x5SinglePhotoPicker(isPresented: $showingLogoPicker)", generator)
        self.assertNotIn("PhotosPicker(selection: $mainPhotoItem", generator)
        self.assertNotIn("PhotosPicker(selection: $logoItem", generator)
        self.assertEqual(editor.count(".x5SinglePhotoPicker("), 2)
        self.assertNotIn(".photosPicker(isPresented:", editor)

    def test_portfolio_tile_size_does_not_depend_on_the_picture(self):
        portfolio = read(VIEWS / "PortfolioView.swift")
        cell = portfolio.split("private struct PortfolioGridCell", 1)[1].split("private var imageURLString", 1)[0]
        self.assertIn(".aspectRatio(3 / 4, contentMode: .fit)\n                .overlay { tileContent }", cell)

    def test_home_cards_take_taps_only_inside_their_shape(self):
        home = read(VIEWS / "Home" / "HomeView.swift")
        self.assertIn(".contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))", home)
        self.assertIn(".contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))", home)
        self.assertIn('handle(imageAction("target_ad"))', home)

    def test_profile_tile_says_hub_tasks_come_an_hour_earlier(self):
        loc = read(ROOT / "X5" / "Services" / "LocalizationService.swift")
        self.assertIn('"profile_verified_sub": "1000 ₸/мес. Задания в разделе Hub приходят на час раньше."', loc)
        self.assertEqual(loc.count('"profile_verified_sub":'), 3)


if __name__ == "__main__":
    unittest.main()
