from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOOPING_VIDEO = ROOT / "X5" / "Views" / "Home" / "LoopingVideo.swift"
HOME_VIEW = ROOT / "X5" / "Views" / "Home" / "HomeView.swift"
PROJECT = ROOT / "project.yml"
SOURCES = ROOT / "THIRD_PARTY_SOURCES.md"
PROVENANCE = ROOT / "docs" / "home-media-provenance.md"
MOTION_DIR = ROOT / "X5" / "Resources" / "HomeMotion"
ASSETS = ROOT / "X5" / "Assets.xcassets"


class HomeMotionSourceTests(unittest.TestCase):
    def test_loop_uses_one_plain_avplayer_and_never_the_crashing_queue_looper(self):
        source = LOOPING_VIDEO.read_text(encoding="utf-8")

        self.assertIn("AVPlayer(playerItem: item)", source)
        self.assertIn(".AVPlayerItemDidPlayToEndTime", source)
        self.assertIn("seek(to: .zero)", source)
        self.assertNotIn("AVQueuePlayer", source)
        self.assertNotIn("AVPlayerLooper", source)

    def test_loop_pauses_offscreen_and_in_background_with_a_static_poster(self):
        source = LOOPING_VIDEO.read_text(encoding="utf-8")

        self.assertIn("@Environment(\\.scenePhase)", source)
        self.assertIn("@Environment(\\.accessibilityReduceMotion)", source)
        self.assertIn("NSProcessInfoPowerStateDidChange", source)
        self.assertIn("HomeMotionPlaybackPolicy.shouldPlay(", source)
        self.assertIn("isVisible", source)
        self.assertIn("player?.pause()", source)
        self.assertIn("if let posterAssetName", source)

    def test_release_uses_bundled_x5_owned_trend_media(self):
        loop = LOOPING_VIDEO.read_text(encoding="utf-8")
        home = HOME_VIEW.read_text(encoding="utf-8")

        self.assertIn("case remote(url: URL)", loop)
        self.assertIn("case .remote(let url):", loop)
        self.assertIn(
            'url.path.hasPrefix("/storage/v1/object/public/videos/home/")',
            loop,
        )
        self.assertIn("case video(HomeMotionSource)", home)
        for name in (
            "HomeTrendStrawberry",
            "HomeTrendTokayev",
            "HomeTrendAIStylist",
            "HomeTrendFaceSwap",
        ):
            self.assertIn(name, home)
        self.assertNotIn('resourceName: "HomeTrendTransitions"', home)
        self.assertNotIn('resourceName: "HomeTrendLipSync"', home)
        self.assertNotIn("HomeMotionURLs", home)
        self.assertNotIn("source: .remote(url: item.videoURL)", home)
        for forbidden in (
            "static.higgsfield.ai",
            "cdn.higgsfield.ai",
            "instagram.com/reel",
            "http://",
        ):
            self.assertNotIn(forbidden, home)
            self.assertNotIn(forbidden, loop)

    def test_visible_trend_videos_are_automatic_and_do_not_need_tap_state(self):
        source = HOME_VIEW.read_text(encoding="utf-8")

        self.assertIn("isActive: true", source)
        self.assertNotIn("@State private var activeTrendVideoID: String?", source)
        self.assertNotIn("activeTrendVideoID == item.id", source)
        self.assertNotIn("isMotionActive: item.showsPlay", source)

    def test_client_selected_reference_cards_use_the_requested_videos(self):
        source = HOME_VIEW.read_text(encoding="utf-8")

        self.assertIn('title: "Измена клубнички"', source)
        self.assertIn('title: "С Токаевым"', source)
        self.assertIn('resourceName: "HomeTrendStrawberry"', source)
        self.assertIn('resourceName: "HomeTrendTokayev"', source)
        self.assertNotIn("motion: .placeholder", source)
        self.assertNotIn("X5 ORIGINAL", source)
        self.assertNotIn("referencePoster", source)
        self.assertNotIn("HomeReferenceMotionPhoto", source)
        self.assertNotIn('resourceName: "HomeTrendTransitions"', source)
        self.assertNotIn('resourceName: "HomeTrendLipSync"', source)

    def test_trend_autoplay_respects_motion_and_power_preferences(self):
        home = HOME_VIEW.read_text(encoding="utf-8")
        loop = LOOPING_VIDEO.read_text(encoding="utf-8")

        self.assertIn("isUserInitiated: false", home)
        self.assertIn("isUserInitiated: Bool = false", loop)
        self.assertIn("isUserInitiated || (!reduceMotion && !lowPowerMode)", loop)
        self.assertNotIn("guard motionPreviewAllowed", home)

    def test_motion_visibility_uses_live_geometry_instead_of_null_preference_frame(self):
        source = LOOPING_VIDEO.read_text(encoding="utf-8")

        self.assertIn(".onGeometryChange(for: Bool.self)", source)
        self.assertNotIn("HomeMotionFramePreferenceKey", source)

    def test_bundled_motion_fallbacks_remain_available(self):
        source = LOOPING_VIDEO.read_text(encoding="utf-8")

        self.assertIn("case bundled(resourceName: String)", source)
        self.assertIn("HomeLoopingVideoController(source: source)", source)
        bundled_names = {path.name for path in MOTION_DIR.glob("*.mp4")}
        self.assertEqual(
            bundled_names,
            {
                "HomeMotionStudio.mp4",
                "HomeMotionFruit.mp4",
                "HomeTrendStrawberry.mp4",
                "HomeTrendTokayev.mp4",
                "HomeTrendAIStylist.mp4",
                "HomeTrendFaceSwap.mp4",
            },
        )

    def test_optimized_fallback_loops_and_posters_are_bundled(self):
        expected_videos = {
            "HomeMotionStudio.mp4": 1_500_000,
            "HomeMotionFruit.mp4": 1_500_000,
            "HomeTrendStrawberry.mp4": 1_100_000,
            "HomeTrendTokayev.mp4": 2_300_000,
            "HomeTrendAIStylist.mp4": 300_000,
            "HomeTrendFaceSwap.mp4": 100_000,
        }
        for filename, maximum_bytes in expected_videos.items():
            path = MOTION_DIR / filename
            self.assertTrue(path.is_file(), filename)
            self.assertLess(path.stat().st_size, maximum_bytes, filename)
            self.assertIn(b"ftyp", path.read_bytes()[:32], filename)

        for asset_name in (
            "HomeMotionStudioPoster",
            "HomeMotionFruitPoster",
            "HomeTrendLiveVideo",
            "HomeTrendPost",
        ):
            imageset = ASSETS / f"{asset_name}.imageset"
            self.assertTrue((imageset / "Contents.json").is_file(), asset_name)
            posters = list(imageset.glob("*.jpg"))
            self.assertEqual(len(posters), 1, asset_name)
            self.assertLess(posters[0].stat().st_size, 200_000, asset_name)

        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn("- path: X5/Resources/HomeMotion", project)

    def test_release_and_legacy_media_provenance_are_recorded(self):
        sources = SOURCES.read_text(encoding="utf-8")
        provenance = PROVENANCE.read_text(encoding="utf-8")

        self.assertIn("https://www.pexels.com/legal-pages/license/", sources)
        self.assertIn("debug-only", sources.lower())
        self.assertIn("X5-owned", provenance)
        self.assertIn("Higgsfield", provenance)
        self.assertIn("client-selected instagram trend clips", sources.lower())
        self.assertIn("DXoWkuziCX6", provenance)
        self.assertIn("C8RAdTZtCoT", provenance)
        self.assertIn("HomeTrendStrawberry", provenance)
        self.assertIn("HomeTrendTokayev", provenance)
        self.assertIn("HomeTrendTransitions", provenance)
        self.assertIn("removed from the app bundle", provenance)
        self.assertIn("face-swap.mp4", provenance)
        self.assertIn("visible cards", provenance.lower())
        self.assertIn("Instagram", provenance)


if __name__ == "__main__":
    unittest.main()
