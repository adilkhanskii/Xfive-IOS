from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
COURSES_VIEW = ROOT / "X5" / "Views" / "CoursesView.swift"


class CourseAuthorNavigationSourceTests(unittest.TestCase):
    def test_every_real_course_author_opens_public_profile_by_author_id(self):
        source = COURSES_VIEW.read_text(encoding="utf-8")
        course_author_rows = re.findall(
            r"CourseAuthorLine\(\s*authorName: course\.authorName.*?\)",
            source,
            flags=re.DOTALL,
        )

        self.assertIn("let authorId: String?", source)
        self.assertIn("NavigationLink", source)
        self.assertIn("UserProfileView(userId: authorId, fallback: nil)", source)
        self.assertEqual(
            len(course_author_rows),
            4,
            f"expected four real course author rows, got {course_author_rows}",
        )
        for row in course_author_rows:
            self.assertIn("authorId: course.authorId", row)


if __name__ == "__main__":
    unittest.main()
