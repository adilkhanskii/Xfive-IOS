import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "project.yml"
UPLOADER = ROOT / "X5" / "Services" / "SupabaseResumableVideoUploader.swift"
COURSES_SERVICE = ROOT / "X5" / "Services" / "CoursesService.swift"
PREPARATION = ROOT / "X5" / "Services" / "CourseVideoUploadPreparation.swift"
LICENSE = ROOT / "X5" / "Resources" / "ThirdParty" / "TUSKit-LICENSE.txt"
EXPORTER_LICENSE = (
    ROOT
    / "X5"
    / "Resources"
    / "ThirdParty"
    / "NextLevelSessionExporter-LICENSE.txt"
)
SOURCES = ROOT / "THIRD_PARTY_SOURCES.md"


class IOSResumableVideoUploadSourceTests(unittest.TestCase):
    def test_xcodegen_pins_audited_tuskit_timeout_patch_and_links_product(self):
        project = PROJECT.read_text(encoding="utf-8")

        self.assertIn("https://github.com/tooyakov-art/TUSKit.git", project)
        self.assertIn(
            'revision: "4fd278f37b8a20f826a6fa45ae12b18b47b058b6"',
            project,
        )
        self.assertIn("- package: TUSKit", project)
        self.assertIn("product: TUSKit", project)
        self.assertIn("- path: X5/Resources/ThirdParty", project)

    def test_uploader_uses_supabase_tus_contract(self):
        source = UPLOADER.read_text(encoding="utf-8")

        self.assertIn("import TUSKit", source)
        self.assertIn("storage/v1/upload/resumable", source)
        self.assertIn("6 * 1024 * 1024", source)
        for key in ("bucketName", "objectName", "contentType", "cacheControl"):
            self.assertIn(f'"{key}"', source)
        self.assertIn("URLSessionConfiguration.ephemeral", source)
        self.assertIn("timeoutIntervalForRequest = 300", source)
        self.assertIn('headers["Authorization"] = "Bearer \\(token)"', source)
        self.assertIn("accessTokenProvider", source)
        self.assertIn("persistGeneratedHeaders: false", source)
        self.assertIn("uploadFileAt(", source)
        self.assertIn("progressFor(", source)
        self.assertIn("try? client.resume(id:", source)
        self.assertIn("scheduleResumeWatchdog", source)
        self.assertIn("cancelAndDelete(id:", source)
        self.assertIn("func fileError(id:", source)
        self.assertIn(".now() + 960", source)

    def test_courses_service_routes_both_video_flows_through_resumable_uploader(self):
        source = COURSES_SERVICE.read_text(encoding="utf-8")

        self.assertGreaterEqual(source.count("resumableVideoUploader.upload("), 2)
        self.assertNotIn("URLSession.shared.upload(for:", source)
        self.assertIn("@Published private(set) var videoUploadProgress", source)
        self.assertGreaterEqual(
            source.count("CourseVideoUploadIdentity.stableToken("),
            2,
        )

    def test_large_videos_are_prepared_before_both_upload_flows(self):
        project = PROJECT.read_text(encoding="utf-8")
        service = COURSES_SERVICE.read_text(encoding="utf-8")
        uploader = UPLOADER.read_text(encoding="utf-8")
        preparation = PREPARATION.read_text(encoding="utf-8")

        self.assertIn(
            "https://github.com/NextLevel/NextLevelSessionExporter.git",
            project,
        )
        self.assertIn(
            'revision: "1bb6e19731ff512f4652f8ce2a8f67c779b1598f"',
            project,
        )
        self.assertIn("import SessionExporter", preparation)
        self.assertIn("static let directUploadLimitBytes", preparation)
        self.assertIn("AVVideoAverageBitRateKey", preparation)
        self.assertIn("exporter.videoComposition", preparation)
        self.assertIn("CourseVideoCompositionTransform.make(", preparation)
        self.assertIn("exporter.preserveHDR = false", preparation)
        self.assertIn("isAcceptablePreparedOutput", preparation)
        self.assertIn("AVAssetExportPresetMediumQuality", preparation)
        self.assertIn(
            "fileLengthLimit = CourseVideoUploadPolicy.transcodeTargetBytes",
            preparation,
        )
        self.assertIn("primaryExporter", preparation)
        self.assertIn("fallbackExporter", preparation)
        self.assertIn("CourseVideoExportDiagnostic", preparation)
        self.assertGreaterEqual(
            preparation.count("loadTracks("),
            2,
        )
        self.assertGreaterEqual(
            service.count("videoUploadPreparer.prepare("),
            2,
        )
        self.assertIn(
            "CourseVideoUploadPolicy.requiresTranscoding",
            uploader,
        )
        self.assertIn("fromUploadFailure", uploader)
        self.assertIn("shouldDiscardResumableState", uploader)
        self.assertIn("client.cancelAndDelete(id: id)", uploader)

    def test_tuskit_license_and_provenance_are_preserved(self):
        license_text = LICENSE.read_text(encoding="utf-8")
        exporter_license = EXPORTER_LICENSE.read_text(encoding="utf-8")
        sources = SOURCES.read_text(encoding="utf-8")

        self.assertIn("Copyright (c) 2015 tus", license_text)
        self.assertIn("The MIT License (MIT)", license_text)
        self.assertIn("TUSKit", sources)
        self.assertIn("3.7.1", sources)
        self.assertIn("167938293923b5c31ba1255da5aada8e67533984", sources)
        self.assertIn("4fd278f37b8a20f826a6fa45ae12b18b47b058b6", sources)
        self.assertIn("timeoutIntervalForRequest", sources)
        self.assertIn("patrick piemonte", exporter_license)
        self.assertIn("1bb6e19731ff512f4652f8ce2a8f67c779b1598f", sources)


if __name__ == "__main__":
    unittest.main()
