from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
HUB_VIEW = ROOT / "X5" / "Views" / "Hub" / "HubView.swift"
HUB_SERVICE = ROOT / "X5" / "Services" / "HubService.swift"


class HubCountsAndCancellationSourceTests(unittest.TestCase):
    def test_all_tile_counts_exactly_what_the_list_shows(self):
        hub = HUB_VIEW.read_text(encoding="utf-8")

        # The "Все" tile and the list it opens must come from one source, or the
        # tile promises two specialists and then shows three.
        self.assertIn("case .specialists:\n            return visibleSpecialists.count", hub)
        self.assertNotIn(".filter { $0.id != auth.userId }", hub)

        # Category tiles already count the same collection.
        self.assertIn("for person in visibleSpecialists {", hub)

    def test_cancelled_reloads_are_not_reported_as_failures(self):
        service = HUB_SERVICE.read_text(encoding="utf-8")

        self.assertIn("private func recordFailure(_ error: Error) {", service)
        self.assertIn("if error is CancellationError { return }", service)
        self.assertIn(
            "if let urlError = error as? URLError, urlError.code == .cancelled { return }",
            service,
        )

        # Every catch must go through the filter, never straight to the banner.
        self.assertNotIn("self.error = error.localizedDescription\n            return", service)
        self.assertEqual(service.count("recordFailure(error)"), 7)
        self.assertEqual(service.count("self.error = error.localizedDescription"), 1)


if __name__ == "__main__":
    unittest.main()
