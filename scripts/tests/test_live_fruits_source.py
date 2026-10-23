from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "X5" / "Services" / "FruitStoryService.swift"
VIEW = ROOT / "X5" / "Views" / "Home" / "LiveFruitsView.swift"
SUPABASE_CLIENT = ROOT / "X5" / "Services" / "SupabaseClient.swift"
SWIFT_TESTS = ROOT / "X5Tests" / "FruitStoryServiceTests.swift"
EDGE = ROOT / "supabase" / "functions" / "fruit-story" / "index.ts"
AMBIGUOUS_RETRY_MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260814003000_retry_ambiguous_fruit_story_requests.sql"
)


class LiveFruitsSourceTests(unittest.TestCase):
    def test_native_story_service_uses_authenticated_x5_edge_function(self):
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("functions/v1/fruit-story", service)
        self.assertIn('"aspect_ratio"', service)
        self.assertIn("Bearer", service)
        self.assertNotIn("OPENAI_API_KEY", service)
        self.assertNotIn("api.openai.com", service)

    def test_story_contract_requires_exactly_three_scenes(self):
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("scenes.count == 3", service)
        self.assertIn("FruitStoryVideoPromptBuilder", service)
        self.assertIn("characterBible", service)
        self.assertIn("visualPrompt", service)
        self.assertIn("camera", service)

    def test_live_fruits_screen_has_questionnaire_editable_storyboard_and_real_video_submit(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn('navigationTitle("Живые фрукты")', view)
        for field in ("fruit", "personality", "goal", "location", "event", "ending"):
            self.assertIn(field, view)
        self.assertIn("FruitStoryService", view)
        self.assertIn(".onMove", view)
        self.assertIn("auth.supabase.generateImage", view)
        self.assertIn("referenceImages", view)
        self.assertIn("VideoGenerationService", view)
        self.assertIn("durationSeconds: 10", view)
        self.assertIn('aspectRatio: "9:16"', view)
        self.assertIn("Xfive marketing", view)
        self.assertNotIn("Скоро добавим", view)

    def test_edge_function_keeps_openai_secret_server_side_and_moderates(self):
        edge = EDGE.read_text(encoding="utf-8")

        self.assertIn('Deno.env.get("OPENAI_API_KEY")', edge)
        self.assertIn("/v1/responses", edge)
        self.assertIn("/v1/moderations", edge)
        self.assertIn('"json_schema"', edge)
        self.assertIn("strict: true", edge)
        self.assertIn("verifyUser", edge)
        self.assertNotIn("service_role", edge.lower())

    def test_first_video_frame_is_center_cropped_to_exact_nine_by_sixteen(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("enum FruitStoryStartImagePreparer", service)
        self.assertIn("UIGraphicsImageRenderer", service)
        self.assertRegex(
            service,
            r"targetPixelSize\s*=\s*CGSize\(\s*width:\s*720,\s*height:\s*1_280\s*\)",
        )
        self.assertIn(
            "FruitStoryStartImagePreparer.makeStartImage(from: frame)",
            view,
        )
        self.assertNotIn("frame.jpegData(compressionQuality:", view)
        self.assertIn("startImage: startImage", view)
        self.assertIn('aspectRatio: "9:16"', view)
        self.assertIn("durationSeconds: 10", view)

    def test_single_scene_regeneration_preserves_reference_order_and_other_frames(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")
        function = re.search(
            r"private func regenerateFrame\(for scene: FruitStoryScene\) \{"
            r"(?P<body>.*?)"
            r"\n    private func submitVideo",
            view,
            flags=re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group("body")
        self.assertIn("@State private var regeneratingSceneID: String?", view)
        self.assertIn(
            "regenerateFrame(for: scene.wrappedValue)",
            view,
        )
        self.assertIn(
            "FruitStoryFrameRegeneration.replacingFrame",
            body,
        )
        self.assertIn("characterReferenceBase64", body)
        self.assertIn("referenceImages: referenceImages", body)
        self.assertRegex(
            body,
            r"guard\s+!isCreatingFrames,\s+regeneratingSceneID == nil",
        )
        self.assertNotIn("frameBase64BySceneID = [:]", body)
        self.assertNotIn("characterReferenceBase64 =", body)
        self.assertNotIn("scenes =", body)
        self.assertIn("regeneratingSceneID != nil", view)
        self.assertIn(
            "Не удалось пересоздать выбранный кадр. Остальные кадры сохранены.",
            body,
        )

    def test_scene_reordering_keeps_frames_and_visual_edits_invalidate_only_one_scene(self):
        view = VIEW.read_text(encoding="utf-8")
        swift_tests = SWIFT_TESTS.read_text(encoding="utf-8")

        self.assertIn("enum LiveFruitsFrameLedger", view)
        self.assertIn("visualFingerprint(for:", view)
        self.assertIn("reconciled(", view)
        self.assertIn("frameFingerprintBySceneID", view)
        self.assertNotRegex(
            view,
            r"\.onChange\(of:\s*scenes\)\s*\{[^}]*"
            r"frameBase64BySceneID\s*=\s*\[:\]",
        )
        self.assertNotRegex(
            view,
            r"private func moveScenes[\s\S]{0,400}"
            r"frameBase64BySceneID\s*=\s*\[:\]",
        )
        self.assertIn(
            "testFrameLedgerPreservesReorderedFramesAndInvalidatesOnlyEditedScene",
            swift_tests,
        )

    def test_every_live_fruits_operation_is_tracked_cancelled_and_account_guarded(self):
        view = VIEW.read_text(encoding="utf-8")

        for task in (
            "storyTask",
            "frameGenerationTask",
            "frameRegenerationTask",
            "videoSubmissionTask",
            "videoPollTask",
            "videoRestoreTask",
        ):
            self.assertIn(
                f"@State private var {task}: Task<Void, Never>?",
                view,
            )
            self.assertIn(f"{task}?.cancel()", view)
        self.assertIn("cancelAllOperations()", view)
        self.assertIn(".onChange(of: auth.userId)", view)
        self.assertIn("beginAccountLifecycle(for:", view)
        self.assertIn("auth.userId?.lowercased() == userID", view)
        self.assertIn("lifecycleID == sessionID", view)
        self.assertIn("Task.checkCancellation()", view)
        self.assertIn("resetAccountState()", view)

    def test_paid_image_calls_use_durable_account_scoped_idempotency_keys(self):
        view = VIEW.read_text(encoding="utf-8")
        service = SERVICE.read_text(encoding="utf-8")
        client = SUPABASE_CLIENT.read_text(encoding="utf-8")

        self.assertIn("idempotencyKey: String? = nil", client)
        self.assertIn(
            'request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")',
            client,
        )
        self.assertIn("LiveFruitsImagePendingRequestStore", service)
        self.assertIn("LiveFruitsImageRequestFingerprint", service)
        self.assertIn("imagePendingStore.requestID(", view)
        self.assertIn("imagePendingStore.clear(", view)
        self.assertIn('slot: "character"', view)
        self.assertIn('slot: "frame.\\(scene.id)"', view)
        self.assertIn('slot: "regenerate.\\(requestedScene.id)"', view)
        self.assertNotIn("let characterRequestID = UUID().uuidString", view)
        self.assertNotIn("let frameRequestID = UUID().uuidString", view)
        self.assertNotIn("let regenerationRequestID = UUID().uuidString", view)
        self.assertGreaterEqual(view.count("idempotencyKey:"), 3)

    def test_paid_image_calls_use_the_captured_account_token(self):
        view = VIEW.read_text(encoding="utf-8")
        client = SUPABASE_CLIENT.read_text(encoding="utf-8")

        self.assertIn("func generateImageWithAccessToken(", client)
        self.assertIn("accessToken: String", client)
        self.assertIn("let imageAccessToken = await auth.freshAccessToken()", view)
        self.assertIn("accessToken: imageAccessToken", view)
        self.assertIn(
            "auth.supabase.generateImageWithAccessToken(",
            view,
        )

    def test_supabase_refresh_cannot_overwrite_a_changed_session(self):
        client = SUPABASE_CLIENT.read_text(encoding="utf-8")

        self.assertIn("sessionGeneration", client)
        self.assertIn("expectedGeneration", client)
        self.assertIn("guard sessionGeneration == expectedGeneration", client)
        self.assertIn("try Task.checkCancellation()", client)

    def test_story_request_id_is_stable_until_success_or_input_change(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn('case requestID = "request_id"', service)
        self.assertIn("FruitStoryPendingRequestStore", service)
        self.assertIn("FruitStoryQuestionnaireFingerprint", service)
        self.assertIn("storyPendingStore.requestID(", view)
        self.assertIn("requestID: requestID", view)
        self.assertIn("storyPendingStore.clear(", view)
        self.assertIn("envelope.requestID == requestID", service)
        self.assertIn('payload.error.code == "outcome_unknown"', service)
        self.assertIn("case outcomeUnknown", service)

    def test_ambiguous_story_request_is_reclaimed_with_the_same_idempotent_request(self):
        service = SERVICE.read_text(encoding="utf-8")
        edge = EDGE.read_text(encoding="utf-8")
        migration = AMBIGUOUS_RETRY_MIGRATION.read_text(encoding="utf-8")

        self.assertIn("maximumRecoveryAttempts", service)
        self.assertIn('safeCode == "outcome_unknown"', service)
        self.assertIn('return safeError("outcome_unknown", 409, 3)', edge)
        self.assertRegex(
            migration,
            r"request\.status = 'ambiguous'[\s\S]{0,120}"
            r"v_reclaim_existing := true",
        )
        self.assertIn("lease_generation = v_lease_generation", migration)
        self.assertIn("fruit_story_request_attempts", migration)

    def test_final_video_reuses_per_account_pending_key_and_restores_accepted_jobs(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("VideoGenerationLocalStore", view)
        self.assertIn("VideoGenerationInputFingerprint.make", view)
        self.assertRegex(view, r"pendingIdempotencyKey\s*\(\s*for:")
        self.assertIn("localStore.remember(jobID:", view)
        self.assertIn("localStore.clearPending(", view)
        self.assertIn("localStore.recentJobIDs(userID:", view)
        self.assertIn("restoreRecentVideoJobs(", view)
        self.assertIn("videoService.status(", view)
        self.assertNotIn("idempotencyKey: UUID().uuidString", view)


if __name__ == "__main__":
    unittest.main()
