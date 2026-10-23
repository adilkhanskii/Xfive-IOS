"""Source wiring only; CurrentUserSessionIsolationTests exercises runtime fences."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class AccountOperationWiring(unittest.TestCase):
    def test_course_retry_uses_owner_and_epoch_fence(self):
        source = (ROOT / "X5/Views/CoursesView.swift").read_text(encoding="utf-8")
        purchase = source.split("private func completePurchase()", 1)[1]
        self.assertGreaterEqual(purchase.count("accessTokenForOperation(profileOperation"), 2)
        self.assertIn("expectedUserId: profileOperation.userID", purchase)

    def test_image_series_never_reads_mutable_session_between_frames(self):
        source = (ROOT / "X5/Views/Home/ImageGeneratorView.swift").read_text(encoding="utf-8")
        self.assertNotIn("auth.supabase.generateImage(", source)
        self.assertGreaterEqual(source.count("generateImageWithAccessToken("), 2)
        self.assertIn("accessToken: operationToken", source)
        series = source.split("private func generateFrameSeries(", 1)[1].split("private func productCardBrief", 1)[0]
        self.assertGreaterEqual(series.count("currentUser.isCurrent(operation)"), 2)
        self.assertIn("accessToken: accessToken", series)

    def test_paid_voice_callers_fence_token_acquisition(self):
        for filename, method in [
            ("AIInfluencerView.swift", "private func generateVoiceTest()"),
            ("VoiceGeneratorView.swift", "private func generate()"),
            ("LipsyncView.swift", "private func start()"),
        ]:
            with self.subTest(filename=filename):
                source = (ROOT / "X5/Views/Home" / filename).read_text(encoding="utf-8")
                body = source.split(method, 1)[1].split("\n    private func", 1)[0]
                self.assertIn("accessTokenForOperation(profileOperation", body)
                self.assertIn("currentUser.isCurrent(profileOperation)", body)


if __name__ == "__main__":
    unittest.main()
