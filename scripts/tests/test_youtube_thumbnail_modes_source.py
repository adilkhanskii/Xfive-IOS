from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
HOME_DATA = ROOT / "X5" / "Views" / "Home" / "HomeData.swift"
GENERATOR = ROOT / "X5" / "Views" / "Home" / "ImageGeneratorView.swift"
HOME = ROOT / "X5" / "Views" / "Home" / "HomeView.swift"


class YouTubeThumbnailModeSourceTests(unittest.TestCase):
    def test_catalog_has_ten_clear_youtube_thumbnail_modes_with_examples(self):
        source = HOME_DATA.read_text(encoding="utf-8")

        self.assertIn("struct YouTubeThumbnailMode", source)
        for mode_id in (
            "entertainment",
            "serious",
            "expert",
            "news",
            "provocative",
            "minimal",
            "interview",
            "review",
            "comparison",
            "story",
        ):
            self.assertIn(f'id: "{mode_id}"', source)
        self.assertIn("let examples: [String]", source)
        self.assertGreaterEqual(source.count("examples: ["), 10)
        self.assertIn("enum YouTubeThumbnailBriefBuilder", source)
        self.assertIn("mode.promptGuidance", source)

    def test_youtube_generator_exposes_mode_picker_without_ready_ideas(self):
        source = GENERATOR.read_text(encoding="utf-8")

        self.assertIn("@State private var selectedYouTubeMode", source)
        self.assertIn("if isYouTubeThumbnailCategory", source)
        self.assertIn("youtubeModePanel", source)
        self.assertIn("ForEach(YouTubeThumbnailMode.all)", source)
        self.assertNotIn("ForEach(selectedYouTubeMode.examples", source)
        self.assertNotIn('Text("Готовые идеи")', source)
        self.assertIn('title: "Фото героя"', source)
        self.assertIn("hasHeroPhoto: mainPhoto != nil", source)
        self.assertIn(
            'category.id == "youtube_cover" ? .landscape : .square',
            source,
        )
        self.assertIn("YouTubeThumbnailBriefBuilder.compose", source)

    def test_existing_home_youtube_card_still_opens_specialized_category(self):
        source = HOME.read_text(encoding="utf-8")

        self.assertIn('id: "youtube"', source)
        self.assertIn('action: imageAction("youtube_cover")', source)

    def test_generator_menus_do_not_show_recommendation_word(self):
        source = GENERATOR.read_text(encoding="utf-8")

        self.assertNotIn("· рекомендуем", source)
        self.assertIn("angle.title", source)
        self.assertIn("mode.title", source)


if __name__ == "__main__":
    unittest.main()
