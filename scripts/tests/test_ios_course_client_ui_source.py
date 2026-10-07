from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IOSCourseClientUISourceTests(unittest.TestCase):
    def test_native_video_picker_keeps_collection_navigation_inside_picker(self):
        picker = (
            ROOT / "X5" / "Views" / "Helpers" / "GalleryVideoPicker.swift"
        ).read_text(encoding="utf-8")
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("PHPickerViewController", picker)
        self.assertIn("PHPickerConfiguration(photoLibrary: .shared())", picker)
        self.assertIn("configuration.filter = .videos", picker)
        self.assertIn("didFinishPicking results", picker)
        self.assertIn("CourseVideoStaging.stage(", picker)
        self.assertIn("temporary URL for the lifetime", picker)
        self.assertIn("GalleryVideoPicker(", editor)
        self.assertNotIn("PhotosPicker(selection: $videoItem, matching: .videos)", editor)

    def test_lesson_cover_gallery_is_presented_from_one_place(self):
        # Сборка 246: в одной строке Form стояли два PhotosPicker обложки урока,
        # тап по строке открывал оба → галерея «вылетала» и открывалась снова.
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("PhotosPicker(selection: $thumbnailItem", editor)
        self.assertEqual(
            editor.count(
                ".photosPicker(isPresented: $showingThumbnailPicker, selection: $thumbnailItem"
            ),
            1,
        )

    def test_courseup_header_and_every_real_course_have_developer_editor_action(self):
        courses = (ROOT / "X5" / "Views" / "CoursesView.swift").read_text(
            encoding="utf-8"
        )
        roles = (ROOT / "X5" / "Services" / "Roles.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn('Text("CourseUP")', courses)
        self.assertNotIn('Text("Академия")', courses)
        # The catalog now contains only server courses. The former membership
        # guard separated synthetic upcoming cards; retain developer-only edit
        # buttons/context menus on both real card paths without requiring fakes.
        self.assertIn("Array(service.courses.dropFirst()) }", courses)
        self.assertNotIn("Self.upcomingCourses", courses)
        featured = courses.split("if let course = featuredCourse {")[1].split("ForEach(Array(academyCourses")[0]
        academy = courses.split("ForEach(Array(academyCourses")[1].split(".padding(.horizontal, 16)")[0]
        for cards in (featured, academy):
            self.assertIn("if isDev {", cards)
            self.assertEqual(cards.count("editorTarget = .edit(course)"), 2)
            self.assertIn("CourseDetailView(course: course", cards)
            self.assertNotIn("CourseInDevelopmentView", cards)
        self.assertEqual(roles.count('"f3eea23f-0aeb-405b-ab35-2c53173b7a8f"'), 1)
        self.assertEqual(roles.count('"eee55a08-18d1-46e3-a303-1411d1bb9333"'), 1)


if __name__ == "__main__":
    unittest.main()
