from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
COURSE_EDITOR = ROOT / "X5" / "Views" / "CourseEditorView.swift"
COURSES_VIEW = ROOT / "X5" / "Views" / "CoursesView.swift"
COURSE_DRAFT = ROOT / "X5" / "Models" / "CourseDraft.swift"
COURSES_SERVICE = ROOT / "X5" / "Services" / "CoursesService.swift"


class CourseLessonDurationSourceTests(unittest.TestCase):
    def test_duration_is_not_rendered_or_editable(self):
        editor = COURSE_EDITOR.read_text(encoding="utf-8")
        courses = COURSES_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("@State private var duration: String", editor)
        self.assertNotIn("lesson.duration", editor)
        self.assertNotIn("totalDurationLabel", courses)
        self.assertNotIn("lesson.duration", courses)
        self.assertNotIn('duration: "08:00"', courses)

    def test_duration_is_removed_from_saved_payload_but_legacy_decode_remains(self):
        draft = COURSE_DRAFT.read_text(encoding="utf-8")
        service = COURSES_SERVICE.read_text(encoding="utf-8")

        self.assertNotIn("var duration: String", draft)
        self.assertNotIn('result["duration"] =', draft)
        self.assertIn('result.removeValue(forKey: "duration")', draft)
        self.assertIn(
            "duration = try container.decodeIfPresent(String.self",
            service,
        )
        self.assertNotIn("try container.encodeIfPresent(duration", service)


if __name__ == "__main__":
    unittest.main()
