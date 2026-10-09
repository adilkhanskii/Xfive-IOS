from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "X5" / "Views" / "CourseVideoPlaybackController.swift"
PLAYER = ROOT / "X5" / "Views" / "LessonPlayerView.swift"


class CourseVideoPlayerSourceTests(unittest.TestCase):
    def test_hls_quality_caps_are_real_avplayer_settings(self) -> None:
        source = CONTROLLER.read_text(encoding="utf-8")

        self.assertIn('pathExtension.lowercased() == "m3u8"', source)
        self.assertIn("preferredPeakBitRate", source)
        self.assertIn("preferredMaximumResolution", source)
        self.assertIn("[.automatic, .p360, .p480, .p720, .p1080]", source)
        self.assertIn("[.original]", source)

    def test_player_reports_network_and_buffering_failures(self) -> None:
        controller = CONTROLLER.read_text(encoding="utf-8")
        player = PLAYER.read_text(encoding="utf-8")

        self.assertIn("NWPathMonitor()", controller)
        self.assertIn("isPlaybackBufferEmpty", controller)
        self.assertIn("isPlaybackLikelyToKeepUp", controller)
        self.assertIn("Слабое соединение", controller)
        self.assertIn("Нет интернета", controller)
        self.assertIn('Button("Повторить")', player)

    def test_bunny_embed_is_resolved_to_hls_without_browser(self) -> None:
        source = CONTROLLER.read_text(encoding="utf-8")

        self.assertIn('"iframe.mediadelivery.net"', source)
        self.assertIn("/playlist.m3u8", source)
        self.assertNotIn("UIApplication.shared.open", source)

    def test_custom_buttons_do_not_overlap_system_player_chrome(self) -> None:
        # Адильхан 09.10: AirPlay наезжал на «Авто», звук — на «на весь экран».
        player = PLAYER.read_text(encoding="utf-8")

        self.assertIn("static let topClearance: CGFloat = 60", player)
        self.assertIn(".padding(.top, SystemPlayerChrome.topClearance)", player)

    def test_fullscreen_zoom_scales_only_the_picture(self) -> None:
        # Адильхан 09.10 22:30: при зуме пауза и ползунок увеличивались вместе с видео.
        player = PLAYER.read_text(encoding="utf-8")
        fullscreen = player[player.index("private struct FullScreenVideoPlayer"):player.index("private final class PlayerTimeline")]

        self.assertNotIn("VideoPlayer(player:", fullscreen)
        self.assertIn("PlayerLayerView(player: playback.player)", fullscreen)
        picture = fullscreen.index("PlayerLayerView(player: playback.player)")
        self.assertLess(picture, fullscreen.index(".scaleEffect(displayedScale)"))
        self.assertLess(fullscreen.index(".scaleEffect(displayedScale)"), fullscreen.index("controls(in: proxy)"))
        self.assertIn('"gobackward.10"', fullscreen)
        self.assertIn('"goforward.10"', fullscreen)
        self.assertIn("Slider(", fullscreen)
        # Кнопки прячутся сами и по тапу (скрин 22:29 — «торчат посередине и не убираются»).
        self.assertIn("controlsVisible = false", fullscreen)
        self.assertIn(".allowsHitTesting(controlsVisible)", fullscreen)
        self.assertIn("if isZoomed {", fullscreen)


if __name__ == "__main__":
    unittest.main()
