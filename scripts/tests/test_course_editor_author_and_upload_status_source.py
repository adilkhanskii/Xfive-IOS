import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
EDITOR = ROOT / "X5" / "Views" / "CourseEditorView.swift"
SERVICE = ROOT / "X5" / "Services" / "CoursesService.swift"


class CourseEditorAuthorAndUploadStatusSourceTests(unittest.TestCase):
    def setUp(self):
        self.editor = EDITOR.read_text(encoding="utf-8")
        self.service = SERVICE.read_text(encoding="utf-8")

    def test_course_author_is_selected_from_real_profiles_and_saved_by_id(self):
        self.assertIn("@State private var selectedAuthorId: String?", self.editor)
        self.assertNotIn('TextField("Автор курса"', self.editor)
        self.assertIn("CourseAuthorPickerSheet(", self.editor)
        self.assertIn("selectedAuthorId = author.id", self.editor)
        self.assertIn("func loadCourseAuthors(accessToken: String) async -> [UserProfile]", self.service)
        self.assertIn(
            'Text(resolvedAuthorId == nil ? "Выбрать" : resolvedAuthorName)',
            self.editor,
        )
        self.assertIn("authorName = matchingAuthor.displayName", self.editor)
        self.assertIn("authorId: resolvedAuthorId,", self.editor)
        self.assertIn('"author_id": resolvedAuthorId,', self.editor)

    def test_video_state_is_clear_from_selection_through_course_save(self):
        self.assertIn("private enum CourseSaveStage: Equatable", self.editor)
        self.assertIn('case uploadingVideo(current: Int, total: Int)', self.editor)
        self.assertIn('"Видео подготовлено"', self.editor)
        self.assertIn('"Загрузится после сохранения курса"', self.editor)
        self.assertIn(
            "saveStage = .uploadingVideo(current: uploaded + 1, total: total)",
            self.editor,
        )
        self.assertIn("saveStage = .savingCourse", self.editor)
        self.assertIn("saveStage = .completed", self.editor)
        self.assertIn("saveStage = .failed(message)", self.editor)


if __name__ == "__main__":
    unittest.main()
