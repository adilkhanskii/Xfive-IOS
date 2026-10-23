from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEWS = ROOT / "X5" / "Views"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AdilkhanEdits20261010EveningSourceTests(unittest.TestCase):
    """Адильхан 10.10 18:01–18:30: галерея снова мигает, «склейка» в плитке, комментарии, значки Hub."""

    def test_photo_gallery_is_not_presented_from_a_form_row(self):
        # Строка Form пересобирается после Face ID → SwiftUI снимал и снова
        # показывал галерею. 20:30: показ через UIKit (255–256) мог залипнуть —
        # теперь обычный .sheet, но только на корне экрана (см. night-тест).
        loader = read(VIEWS / "Helpers" / "PickedPhotoLoader.swift")
        self.assertIn("struct SystemPhotoPicker: UIViewControllerRepresentable", loader)
        self.assertIn("isPresented.wrappedValue = false", loader)
        self.assertIn("configuration.selectionLimit = max(1, limit)", loader)
        self.assertNotIn("X5PhotoPickerPresenter", loader)

    def test_cover_references_use_the_uikit_gallery(self):
        generator = read(VIEWS / "Home" / "ImageGeneratorView.swift")
        self.assertNotIn("PhotosPicker(selection: $referenceItems", generator)
        self.assertNotIn("referenceItems", generator)
        self.assertIn(".x5PhotoPicker(isPresented: $showingReferencePicker, limit: referencePickLimit)", generator)
        self.assertEqual(generator.count("openReferencePicker(maxCount: 4)"), 2)
        self.assertEqual(generator.count("openReferencePicker(maxCount: 6)"), 1)

    def test_video_tile_shows_only_the_top_of_the_cover_composite(self):
        portfolio = read(VIEWS / "PortfolioView.swift")
        crop = portfolio.split("struct PortfolioCoverTopCrop: View", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("Color.clear\n            .overlay(alignment: .top)", crop)
        self.assertIn(".clipped()", crop)
        self.assertEqual(portfolio.count("PortfolioCoverTopCrop(image: image)"), 2)
        self.assertNotIn(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)", portfolio)

    def test_own_comments_can_be_edited_and_deleted(self):
        service = read(ROOT / "X5" / "Services" / "PortfolioService.swift")
        self.assertIn("func deleteComment(commentId: String, accessToken: String) async -> Bool", service)
        self.assertIn("func editComment(_ comment: PortfolioComment, newText: String, accessToken: String)", service)
        # Удалено, только если сервер вернул строку (RLS молча пропускает чужое).
        delete = service.split("func deleteComment(", 1)[1].split("func editComment(", 1)[0]
        self.assertIn('"return=representation"', delete)
        self.assertIn("return !rows.isEmpty", delete)

        portfolio = read(VIEWS / "PortfolioView.swift")
        self.assertIn('Button("Изменить") { startEditing(comment) }', portfolio)
        self.assertIn('Button("Удалить") { commentToDelete = comment }', portfolio)
        self.assertIn('"Удалить комментарий?"', portfolio)
        self.assertIn("currentUserId: auth.userId", portfolio)

    def test_hub_tiles_have_a_real_accountant_icon_and_fit_long_words(self):
        hub = read(ROOT / "X5" / "Services" / "HubService.swift")
        self.assertNotIn('return "calculator.fill"', hub)
        self.assertIn('case "accountant": return "plus.forwardslash.minus"', hub)
        tile = read(VIEWS / "Hub" / "HubView.swift").split("private struct CategoryTile: View", 1)[1]
        self.assertIn(".lineLimit(isSingleWord ? 1 : 3)", tile)


if __name__ == "__main__":
    unittest.main()
