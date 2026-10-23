from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260724130000_repair_course_author_from_unique_nickname.sql"
)


class CourseAuthorDataRepairMigrationSourceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(
            MIGRATION.exists(),
            "course author repair migration has not been added",
        )
        self.source = MIGRATION.read_text(encoding="utf-8")
        self.normalized = re.sub(r"\s+", " ", self.source.lower())

    def test_repairs_only_an_exact_unique_nonempty_profile_nickname_match(self):
        self.assertIn("nullif(btrim(p.nickname), '') is not null", self.normalized)
        self.assertIn("group by lower(btrim(p.nickname))", self.normalized)
        self.assertIn("having count(*) = 1", self.normalized)
        self.assertIn(
            "lower(btrim(c.author_name)) = unique_nicknames.normalized_nickname",
            self.normalized,
        )

    def test_skips_courses_whose_linked_profile_already_matches_the_author(self):
        self.assertIn(
            "current_profile.id = c.author_id",
            self.normalized,
        )
        self.assertIn(
            "coalesce( lower(btrim(c.author_name)) = "
            "lower(btrim(current_profile.name)), false )",
            self.normalized,
        )
        self.assertIn(
            "coalesce( lower(btrim(c.author_name)) = "
            "lower(btrim(current_profile.nickname)), false )",
            self.normalized,
        )
        self.assertIn("current_profile.id is null", self.normalized)
        self.assertIn("not (", self.normalized)

    def test_uses_canonical_display_name_and_an_idempotent_update_guard(self):
        self.assertIn(
            "coalesce( nullif(btrim(matched_profile.name), ''), "
            "nullif(btrim(matched_profile.nickname), '') )",
            self.normalized,
        )
        self.assertIn("c.author_id is distinct from repair.profile_id", self.normalized)
        self.assertIn(
            "c.author_name is distinct from repair.canonical_author_name",
            self.normalized,
        )
        self.assertNotRegex(
            self.source,
            r"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
            r"[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        )

    def test_locks_profile_aliases_and_compare_swaps_the_course(self):
        self.assertIn(
            "lock table public.profiles in share mode",
            self.normalized,
        )
        self.assertIn(
            "c.author_id is not distinct from repair.current_author_id",
            self.normalized,
        )
        self.assertIn(
            "c.author_name is not distinct from repair.current_author_name",
            self.normalized,
        )


if __name__ == "__main__":
    unittest.main()
