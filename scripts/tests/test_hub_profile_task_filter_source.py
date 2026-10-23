from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class HubProfileTaskFilterSourceTests(unittest.TestCase):
    def test_second_task_tile_applies_saved_profile_categories_without_sheet(self):
        hub = (ROOT / "X5" / "Views" / "Hub" / "HubView.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            "taskBrowseState.showResults(forProfileCategories: "
            "currentUser.profile?.specialistCategory)",
            hub,
        )
        self.assertNotIn("TaskCategoryFilterSheet", hub)
        self.assertNotIn("showingTaskCategoryFilter", hub)

    def test_state_and_catalog_define_normalized_profile_filter_contract(self):
        state = (
            ROOT / "X5" / "Views" / "Hub" / "HubTaskBrowseState.swift"
        ).read_text(encoding="utf-8")
        catalog = (ROOT / "X5" / "Services" / "HubService.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("showResults(forProfileCategories", state)
        self.assertIn("HubCategories.normalizedIDs(from:", state)
        self.assertIn("guard !categoryIds.isEmpty", state)
        self.assertIn("page = .categories", state)
        self.assertIn("static func normalizedIDs(from values: [String]?)", catalog)
        self.assertIn("validCategoryIds.contains", catalog)


if __name__ == "__main__":
    unittest.main()
