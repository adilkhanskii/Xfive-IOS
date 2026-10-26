from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEWS = ROOT / "X5" / "Views"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AdilkhanHomeSwap20261026SourceTests(unittest.TestCase):
    """Адильхан 26.10 15:03–15:07: карточки и генерация местами, новые обложки, процент генерации."""

    def test_youtube_tile_uses_the_client_cover_without_a_second_title(self):
        home = read(VIEWS / "Home" / "HomeView.swift")
        items = home.split("private var businessItems", 1)[1].split("private var hasBusinessTools", 1)[0]
        self.assertIn('assetName: "HomeCoverYoutube"', items)
        self.assertIn("coverHasText: true", items)
        self.assertIn("showsText: !item.coverHasText", home)

    def test_generation_card_shows_percent_instead_of_spinner(self):
        gen = read(VIEWS / "Home" / "ImageGeneratorView.swift")
        card = gen.split("private struct GenerationAnimationView", 1)[1].split(
            "private struct GeneratedImageViewer", 1
        )[0]
        self.assertIn('Text("\\(percent)%")', card)
        self.assertIn("TimelineView(.periodic(from: .now, by: 0.25))", card)
        # не 100 %, пока сервер не ответил
        self.assertIn("return min(99, max(0, Int(value)))", card)
        self.assertNotIn("ProgressView()", card)
        self.assertNotIn("generationPulseBars", card)
        self.assertNotIn("Image(systemName: category.icon)", card)
        self.assertIn('loc.t("gen_building_image")', card)

    def test_building_caption_is_grammatical_in_every_language(self):
        loc = read(ROOT / "X5" / "Services" / "LocalizationService.swift")
        self.assertIn('"gen_building_image": "Собираем изображение"', loc)
        self.assertEqual(loc.count('"gen_building_image":'), 3)


if __name__ == "__main__":
    unittest.main()
