from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
HOME = ROOT / "X5" / "Views" / "Home" / "HomeView.swift"


class AdilkhanHomeBannerFull20261026SourceTests(unittest.TestCase):
    """Адильхан 26.10 16:26: «края срезались», наш текст на слайде зачеркнул, тап по всему слайду."""

    def test_product_cards_slide_shows_the_whole_collage_without_overlay(self):
        home = HOME.read_text(encoding="utf-8")
        slides = home.split("private var heroSlides", 1)[1].split("private var imageGenerationCard", 1)[0]
        self.assertIn("fullCover: true", slides)
        self.assertNotIn("shadeLeft", home)

        card = home.split("private struct NativeHomeHeroCard", 1)[1].split("private var overlayBody", 1)[0]
        self.assertIn("if slide.fullCover", card)
        # картинка целиком, нажатие — весь слайд, без «Создать» и без затемнения
        self.assertIn(".scaledToFit()", card)
        self.assertIn("Button(action: action)", card)
        self.assertIn(".contentShape(Rectangle())", card)
        self.assertNotIn('Text("Создать")', card)
        self.assertNotIn("LinearGradient(", card)
        self.assertIn("onLight: true", card)

    def test_youtube_tile_keeps_the_cover_proportion(self):
        home = HOME.read_text(encoding="utf-8")
        self.assertIn("static let textCoverAspect: CGFloat = 3.0 / 2.0", home)
        self.assertIn("content.aspectRatio(HomeLayout.textCoverAspect, contentMode: .fit)", home)
        self.assertIn(".frame(height: showsText ? cardHeight : nil)", home)


if __name__ == "__main__":
    unittest.main()
