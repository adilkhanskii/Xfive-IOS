from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CourseCatalogTruthTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "X5/Views/CoursesView.swift").read_text(encoding="utf-8")

    def test_catalog_does_not_append_invented_courses(self):
        self.assertIn("Array(service.courses.dropFirst()) }", self.source)
        self.assertNotIn("makeUpcomingCourse", self.source)
        self.assertNotIn("Self.upcomingCourses", self.source)

    def test_unknown_student_count_is_not_invented(self):
        self.assertNotIn("fallbackStudents", self.source)
        self.assertNotIn("[156, 201, 98, 143, 89, 124]", self.source)

    def test_empty_catalog_explains_itself_and_can_reload(self):
        self.assertIn('loc.t("courses_empty_title")', self.source)
        self.assertIn('loc.t("courses_empty_message")', self.source)
        self.assertIn('accessibilityIdentifier("Course.catalog.empty")', self.source)
        self.assertIn('.refreshable { await reloadCourses() }', self.source)

