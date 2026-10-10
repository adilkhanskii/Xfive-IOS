from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "X5" / "Services" / "VideoGenerationService.swift"
RESULT_FILE_SERVICE = (
    ROOT / "X5" / "Services" / "VideoGenerationResultFileService.swift"
)
VIEW = ROOT / "X5" / "Views" / "Home" / "VideoGeneratorView.swift"
SWIFT_TESTS = ROOT / "X5Tests" / "VideoGenerationServiceTests.swift"


class IOSVideoGenerationSourceTests(unittest.TestCase):
    def test_native_video_service_uses_x5_backend_not_provider_secret(self):
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("functions/v1/generate-video", service)
        self.assertIn('"idempotency_key"', service)
        self.assertIn('"job_id"', service)
        self.assertNotIn("FAL_KEY", service)
        self.assertNotIn("fal.run", service)
        self.assertNotIn("queue.fal", service)

    def test_video_screen_exposes_real_job_states(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn(".navigationTitle(studioMode.navigationTitle)", view)
        self.assertIn('case .standard: return "Генерация видео"', view)
        self.assertIn("VideoGenerationService", view)
        for state in ("queued", "rendering", "completed", "failed"):
            self.assertIn(f"case .{state}", view)
        self.assertIn("resultURL", view)
        self.assertNotIn("Скоро добавим", view)

    def test_submit_has_text_to_video_controls(self):
        view = VIEW.read_text(encoding="utf-8")
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("durationSeconds", view)
        self.assertIn("aspectRatio", view)
        self.assertIn("VideoGenerationModel", view)
        self.assertIn("Seedance 2.0 Fast · официальный", service)
        self.assertIn(".seedance20Fast", view)
        self.assertIn("VideoGenerationResolution", view)
        self.assertIn("generateAudio", view)
        self.assertIn("submitVideo()", view)
        self.assertIn("estimatedCreditCost", view)
        self.assertIn('"model"', service)
        self.assertIn('"resolution"', service)
        self.assertIn('"generate_audio"', service)

    def test_release_ui_exposes_only_verified_seedance_2_fast(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn(
            "private let model: VideoGenerationModel = .seedance20Fast",
            view,
        )
        self.assertNotIn("ForEach(VideoGenerationModel.allCases)", view)
        self.assertIn("private var availableResolutions", view)
        self.assertIn("[.standard, .hd]", view)

    def test_completed_video_is_downloaded_privately_before_play_share_or_save(self):
        view = VIEW.read_text(encoding="utf-8")
        result_service = RESULT_FILE_SERVICE.read_text(encoding="utf-8")

        self.assertIn("VideoGenerationResultFileService", view)
        self.assertIn("ShareLink(item: localResultURL)", view)
        self.assertIn("PHAssetChangeRequest.creationRequestForAssetFromVideo", view)
        self.assertIn("resultFileService.cleanup(localResultURL)", view)
        self.assertNotIn("AVPlayer(url: resultURL)", view)
        self.assertIn("refreshSignedURL: true", view)
        self.assertIn("let envelope = try await service.status(", view)
        self.assertIn("/storage/v1/object/sign/video-generation-results/", result_service)
        self.assertIn("maximumVideoBytes = 50 * 1024 * 1024", result_service)
        self.assertIn('Array("ftyp".utf8)', result_service)
        self.assertIn("isControlledResultFile", result_service)
        self.assertIn('components(separatedBy: "--")', result_service)

        swift_tests = SWIFT_TESTS.read_text(encoding="utf-8")
        self.assertIn(
            "testRepeatedResultPreparationUsesIndependentLocalFiles",
            swift_tests,
        )
        self.assertIn(
            "testResultCleanupRequiresJobAndPreparationUUIDs",
            swift_tests,
        )

    def test_service_accepts_fractional_supabase_timestamps(self):
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("withFractionalSeconds", service)
        self.assertIn("dateDecodingStrategy = .custom", service)

    def test_image_to_video_uses_existing_photos_picker_pattern_and_jpeg_limit(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("import PhotosUI", view)
        self.assertIn("import UIKit", view)
        # 10.10: галерея UIKit (SwiftUI-шная после Face ID открывалась по кругу);
        # фото по-прежнему приходит файлом, а не Data.
        self.assertIn(".x5SinglePhotoPicker(isPresented: $showingStartImagePicker)", view)
        self.assertIn("PickedPhotoLoader.copyImageFile(", view)
        self.assertIn("Task.detached", view)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", view)
        self.assertNotIn("loadTransferable(type: Data.self)", view)
        self.assertNotIn("UIImage(data: sourceData)", view)
        preparer = view[
            view.index("private enum VideoGenerationStartImagePreparer"):
            view.index("enum VideoGenerationDisplayState")
        ]
        self.assertIn("let worker = Task.detached", preparer)
        self.assertIn("worker.cancel()", preparer)
        self.assertIn("Image(uiImage: startImagePreview)", view)
        self.assertIn("maxStartImageBytes = 8 * 1024 * 1024", service)
        self.assertIn('"start_image"', service)
        self.assertIn('"mime_type"', service)
        self.assertIn('"data_base64"', service)

    def test_recent_jobs_and_ambiguous_submit_are_persisted(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("UserDefaults", service)
        self.assertIn("maximumRecentJobCount = 8", service)
        self.assertIn("remember(jobID:", view)
        self.assertIn("recentJobIDs", view)
        self.assertIn("restoreRecentJobs(", view)
        self.assertIn("startPolling(", view)
        self.assertRegex(view, r"pendingIdempotencyKey\s*\(\s*for:")
        self.assertIn("VideoGenerationInputFingerprint", view)
        self.assertIn("clearPending(", view)
        self.assertIn("forceNewIdempotencyKey: true", view)

    def test_submission_and_polling_are_cancelled_with_the_view_lifecycle(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("@State private var submissionTask: Task<Void, Never>?", view)
        self.assertRegex(view, r"submissionTask\s*=\s*Task")
        self.assertRegex(
            view,
            r"\.onDisappear\s*\{[^}]*submissionTask\?\.cancel\(\)"
            r"[^}]*pollTask\?\.cancel\(\)",
        )
        self.assertIn("catch is CancellationError", view)
        self.assertIn("Task.checkCancellation()", service)
        self.assertIn("throw CancellationError()", service)
        self.assertIn("withTaskCancellationHandler", view)
        self.assertIn("pollGenerationID == generationID", view)
        self.assertRegex(
            view,
            r"guard\s+!Task\.isCancelled,\s*"
            r"isLifecycleCurrent\(sessionID,\s*userID:\s*userID\)",
        )

    def test_recent_and_pending_state_are_scoped_to_the_authenticated_account(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("func recentJobIDs(userID:", service)
        self.assertIn("func remember(jobID: String, userID:", service)
        self.assertIn("func pendingIdempotencyKey(", service)
        self.assertIn("maximumPendingSubmissionCount = 8", service)
        self.assertIn("[PendingSubmission]", service)
        self.assertIn("userID: String", service)
        self.assertIn(".task(id: auth.userId)", view)
        self.assertIn("userID: userID", view)

    def test_only_explicit_owned_job_codes_remove_a_persisted_job(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("makesJobUnavailable", service)
        makes_unavailable = service[
            service.index("var makesJobUnavailable"):
            service.index("var errorDescription")
        ]
        self.assertNotIn("[401, 403, 404]", makes_unavailable)
        self.assertIn('"job_not_found"', makes_unavailable)
        self.assertIn("localStore.remove(jobID:", view)
        self.assertIn("catch is CancellationError", view)

    def test_polling_reuses_current_token_and_retries_refresh_with_bounded_backoff(self):
        service = SERVICE.read_text(encoding="utf-8")
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("requiresAuthenticationRefresh", service)
        self.assertIn("VideoGenerationPollingRetryPolicy", service)
        self.assertIn("JWTAccessTokenValidity.needsRefresh", view)
        self.assertIn("auth.accessToken", view)
        self.assertIn("initialAccessToken:", view)
        self.assertRegex(
            view,
            r"where serviceError\.requiresAuthenticationRefresh[\s\S]*"
            r"stillActive\.append\(jobID\)",
        )
        self.assertRegex(
            view,
            r"let refreshedToken = await accessTokenForVideoRequest\([\s\S]{0,180}"
            r"if refreshedToken != nil \{\s*"
            r"authenticationRefreshRequired = false",
        )
        polling = view[view.index("private func startPolling("):]
        self.assertLessEqual(polling.count("auth.freshAccessToken()"), 1)
        self.assertNotRegex(
            polling,
            r"guard let token = await auth\.freshAccessToken\(\) else \{[\s\S]{0,300}return",
        )

    def test_submit_cancels_and_invalidates_restore_before_mutating_job_state(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("@State private var restoreTask: Task<Void, Never>?", view)
        self.assertIn("@State private var restoreGenerationID = UUID()", view)
        submit = view[
            view.index("private func submitVideo("):
            view.index("private func restoreRecentJobs(")
        ]
        self.assertIn("restoreTask?.cancel()", submit)
        self.assertIn("restoreGenerationID = UUID()", submit)

    def test_accepted_job_is_persisted_before_pending_key_is_cleared(self):
        view = VIEW.read_text(encoding="utf-8")
        accepted = view.index("localStore.remember(jobID: envelope.job.id")
        cleared = view.index("localStore.clearPending(")

        self.assertLess(accepted, cleared)
        self.assertIn("isRestoreCurrent(", view)

    def test_photo_preparation_is_tracked_cancelled_and_generation_guarded(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn(
            "@State private var photoPreparationTask: Task<Void, Never>?",
            view,
        )
        self.assertIn("@State private var photoPreparationID = UUID()", view)
        self.assertIn("photoPreparationTask?.cancel()", view)
        self.assertIn("isPhotoPreparationCurrent(", view)
        self.assertRegex(
            view,
            r"\.onDisappear\s*\{[\s\S]{0,500}photoPreparationTask\?\.cancel\(\)",
        )

    def test_url_protocol_test_transport_has_no_global_mutable_handler(self):
        swift_tests = SWIFT_TESTS.read_text(encoding="utf-8")

        self.assertNotIn("static var handler:", swift_tests)
        self.assertIn("private static let handlerRegistry", swift_tests)
        self.assertIn("private let lock = NSLock()", swift_tests)

    def test_refunded_failure_has_a_distinct_ui_display_state(self):
        view = VIEW.read_text(encoding="utf-8")

        self.assertIn("enum VideoGenerationDisplayState", view)
        self.assertIn("case refunded", view)
        self.assertIn('case .refunded: return "Кредиты возвращены"', view)

    def test_unknown_server_messages_are_not_presented_verbatim(self):
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("private static func safeServerErrorDescription", service)
        self.assertNotIn(": message\n", service)


if __name__ == "__main__":
    unittest.main()
