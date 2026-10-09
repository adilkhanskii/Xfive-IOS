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
        self.assertIn("max(12, proxy.safeAreaInsets.top) + SystemPlayerChrome.topClearance", player)


if __name__ == "__main__":
    unittest.main()
