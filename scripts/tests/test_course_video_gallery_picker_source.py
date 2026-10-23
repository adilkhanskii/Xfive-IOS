from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
COURSE_EDITOR = ROOT / "X5" / "Views" / "CourseEditorView.swift"
COURSES_VIEW = ROOT / "X5" / "Views" / "CoursesView.swift"
GALLERY_PICKER = ROOT / "X5" / "Views" / "Helpers" / "GalleryVideoPicker.swift"


class CourseVideoGalleryPickerSourceTests(unittest.TestCase):
    def test_lesson_video_picker_opens_native_photo_library_instead_of_files(self):
        source = COURSE_EDITOR.read_text(encoding="utf-8")
        picker = GALLERY_PICKER.read_text(encoding="utf-8")

        self.assertIn("@State private var showingVideoPicker = false", source)
        self.assertIn("GalleryVideoPicker(", source)
        self.assertIn("PHPickerViewController", picker)
        self.assertIn("configuration.filter = .videos", picker)
        self.assertNotIn(
            "PhotosPicker(selection: $videoItem, matching: .videos)", source
        )
        self.assertNotIn(".fileImporter(", source)

    def test_submission_video_picker_keeps_collections_inside_native_picker(self):
        source = COURSES_VIEW.read_text(encoding="utf-8")
        picker = GALLERY_PICKER.read_text(encoding="utf-8")

        self.assertIn("@State private var showingVideoPicker = false", source)
        self.assertIn("GalleryVideoPicker(", source)
        self.assertIn("PHPickerConfiguration(photoLibrary: .shared())", picker)
        self.assertIn("didFinishPicking results", picker)
        self.assertNotIn(
            "PhotosPicker(selection: $videoItem, matching: .videos)", source
        )
        self.assertNotIn(".fileImporter(", source)

    def test_picker_delivers_exactly_one_terminal_callback(self):
        picker = GALLERY_PICKER.read_text(encoding="utf-8")

        self.assertIn("private let completionGate", picker)
        self.assertIn("guard completionGate.beginLoading() else { return }", picker)
        self.assertIn("guard completionGate.finishLoading() else", picker)
        self.assertIn("CourseVideoStaging.removeIfManaged(stagedURL)", picker)
        self.assertIn("static func dismantleUIViewController", picker)
        self.assertIn("coordinator.cancel()", picker)

    def test_submission_locks_send_before_first_await(self):
        source = COURSES_VIEW.read_text(encoding="utf-8")
        send = source.split("private func send() async {", 1)[1]

        self.assertLess(
            send.index("isSending = true"),
            send.index("await auth.freshAccessToken()"),
        )

    def test_submission_clears_the_state_url_after_success(self):
        source = COURSES_VIEW.read_text(encoding="utf-8")
        send = source.split("private func send() async {", 1)[1]

        self.assertIn("self.videoFileURL = nil", send)


if __name__ == "__main__":
    unittest.main()
