import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FUNCTIONS = ROOT / "supabase" / "functions"
SHARED = FUNCTIONS / "_shared" / "bunny-stream.mjs"
UPLOAD = FUNCTIONS / "create-course-video-upload"
PLAYBACK = FUNCTIONS / "course-video-playback"
STATUS = FUNCTIONS / "course-video-status"
DOCS = UPLOAD / "DEPLOYMENT.md"
DRAFT = (
    ROOT
    / "supabase"
    / "drafts"
    / "bunny-stream"
    / "20261001090000_course_video_assets.sql"
)
UPLOADER = ROOT / "X5" / "Services" / "BunnyStreamResumableVideoUploader.swift"
DELIVERY = ROOT / "X5" / "Services" / "CourseVideoDelivery.swift"
COURSES = ROOT / "X5" / "Services" / "CoursesService.swift"
PLAYER = ROOT / "X5" / "Views" / "LessonPlayerView.swift"
PROJECT = ROOT / "project.yml"
WORKFLOW = ROOT / ".github" / "workflows" / "ios-course-ci.yml"
SOURCES = ROOT / "THIRD_PARTY_SOURCES.md"
RELEASE_METADATA = (
    ROOT / "fastlane" / "metadata" / "en-US" / "release_notes.txt",
    ROOT / "fastlane" / "metadata" / "ru" / "release_notes.txt",
    ROOT / "docs" / "release-notes" / "1.1.6-build-195" / "kk.txt",
    ROOT / "fastlane" / "metadata" / "review_information" / "notes.txt",
)


class CourseBunnyUploadSourceTests(unittest.TestCase):
    def test_upload_broker_verifies_user_before_service_role_rpc(self):
        handler = (UPLOAD / "handler.mjs").read_text(encoding="utf-8")
        index = (UPLOAD / "index.ts").read_text(encoding="utf-8")

        verify = handler.index("deps.verifyUser(")
        claim = handler.index('"course_video_claim_upload"')
        create = handler.index("bunnyCreateVideo(")
        signature = handler.index("tusSignature(")
        self.assertLess(verify, claim)
        self.assertLess(claim, create)
        self.assertLess(create, signature)
        self.assertNotIn("playback_url", handler)
        self.assertIn("bunnyEnvFromDeno", index)
        self.assertNotIn("RELEASE_ENABLED", index)

    def test_service_role_only_rpcs_and_flag_live_in_sql(self):
        sql = DRAFT.read_text(encoding="utf-8").lower()
        self.assertIn("'bunny_course_video_upload'", sql)
        self.assertIn("return jsonb_build_object('status', 'disabled')", sql)
        self.assertIn(
            "revoke all on table public.course_video_assets\n  from public, anon, authenticated",
            sql,
        )
        self.assertIn(
            "revoke all on function %s from public, anon, authenticated", sql
        )
        self.assertIn("grant execute on function %s to service_role", sql)
        self.assertNotRegex(sql, r"grant [a-z, ]+ to (anon|authenticated)")
        # the old prototype ledger is retired
        self.assertIn("drop table if exists public.course_video_upload_slots", sql)

    def test_playback_is_entitlement_checked_and_token_signed(self):
        handler = (PLAYBACK / "handler.mjs").read_text(encoding="utf-8")
        shared = SHARED.read_text(encoding="utf-8")
        sql = DRAFT.read_text(encoding="utf-8")

        self.assertIn('"course_video_playback_grant"', handler)
        self.assertLess(
            handler.index('"course_video_playback_grant"'),
            handler.index("playbackURL(config"),
        )
        self.assertIn("bcdn_token=", shared)
        self.assertIn("token_path=", shared)
        self.assertIn("purchased_course_ids", sql)
        self.assertIn("purchased_lesson_ids", sql)
        self.assertIn("v_asset.course_id <> p_course_id", sql)

    def test_status_function_never_trusts_webhook_payload(self):
        handler = (STATUS / "handler.mjs").read_text(encoding="utf-8")
        self.assertIn("bunnyGetVideo(", handler)
        self.assertIn("COURSE_VIDEO_CRON_SECRET", handler)
        self.assertIn("timingSafeEqual", handler)
        self.assertNotIn("body.Status", handler)

    def test_ios_uses_runtime_flag_and_keeps_supabase_fallback(self):
        courses = COURSES.read_text(encoding="utf-8")
        uploader = UPLOADER.read_text(encoding="utf-8")
        delivery = DELIVERY.read_text(encoding="utf-8")
        project = PROJECT.read_text(encoding="utf-8")

        self.assertNotIn("X5_ENABLE_BUNNY_COURSE_VIDEO_UPLOAD", project)
        self.assertNotIn("X5_ENABLE_BUNNY_COURSE_VIDEO_UPLOAD", courses)
        self.assertNotIn("X5_ENABLE_BUNNY_COURSE_VIDEO_UPLOAD", uploader)
        self.assertIn("await isBunnyUploadEnabled()", courses)
        self.assertIn('"bunny_course_video_upload"', delivery)
        self.assertIn("return .bunny(videoID: videoID)", courses)
        self.assertIn("return .storageURL(", courses)
        self.assertGreaterEqual(courses.count("resumableVideoUploader.upload("), 2)
        self.assertGreaterEqual(courses.count("videoUploadPreparer.prepare("), 2)
        # submissions stay on Supabase
        self.assertEqual(courses.count("bunnyStreamVideoUploader.upload("), 1)
        for source in (courses, uploader, delivery):
            self.assertNotIn("BUNNY_STREAM_API_KEY", source)
            self.assertNotIn("AccessKey", source)

    def test_ios_player_requests_signed_url_for_bunny_lessons(self):
        player = PLAYER.read_text(encoding="utf-8")
        delivery = DELIVERY.read_text(encoding="utf-8")
        self.assertIn("CourseVideoPlaybackClient(", player)
        self.assertIn("functions/v1/course-video-playback", delivery)
        self.assertIn("refreshURL: makeRefresher()", player)
        self.assertIn('hasSuffix(".b-cdn.net")', delivery)

    def test_ci_runs_all_bunny_function_checks(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        for name in (
            "create-course-video-upload",
            "course-video-playback",
            "course-video-status",
        ):
            self.assertIn(f"supabase/functions/{name}/**", workflow)
            self.assertIn(f"supabase/functions/{name}/index.ts", workflow)
            self.assertIn(f"supabase/functions/{name}/*.test.mjs", workflow)
        self.assertIn("supabase/functions/_shared/bunny-stream.mjs", workflow)

    def test_docs_and_sources_point_to_handoff(self):
        docs = DOCS.read_text(encoding="utf-8")
        sources = SOURCES.read_text(encoding="utf-8")
        self.assertIn("BUNNY-STREAM-HANDOFF.md", docs)
        self.assertIn("BUNNY_STREAM_TOKEN_KEY", docs)
        self.assertIn("https://docs.bunny.net/stream/tus-resumable-uploads", sources)
        self.assertIn("TUSKit", sources)

    def test_release_metadata_does_not_claim_unreleased_bunny_uploads(self):
        metadata = "\n".join(
            path.read_text(encoding="utf-8") for path in RELEASE_METADATA
        )
        for false_claim in (
            "Large course and submission videos",
            "Large lesson/submission videos",
            "Большие видео уроков и заявок",
            "үлкен видеолары",
            "1 GiB",
            "47,000,000",
            "Bunny",
        ):
            self.assertNotIn(false_claim, metadata)


if __name__ == "__main__":
    unittest.main()
