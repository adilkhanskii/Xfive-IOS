import pathlib
import re
import unittest


WORKFLOW = (
    pathlib.Path(__file__).parents[2]
    / ".github"
    / "workflows"
    / "asc-configure-subscriptions.yml"
)


class SubscriptionCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding="utf-8")

    def price_for(self, product_id: str) -> int:
        match = re.search(
            rf'"product_id": "{re.escape(product_id)}".*?'
            r'"price_kaz": Decimal\("(\d+)"\)',
            self.source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, product_id)
        return int(match.group(1))

    def test_legacy_max_price_is_unchanged(self):
        self.assertEqual(self.price_for("com.x5studio.app.max.monthly"), 5_000)

    def test_verified_monthly_price_is_one_thousand_kzt(self):
        self.assertEqual(self.price_for("com.x5studio.app.verified.monthly"), 1_000)

    def test_legacy_subscriptions_are_catalogued_but_not_mutated(self):
        self.assertEqual(self.source.count('"legacy_read_only": True'), 3)
        self.assertIn('if spec.get("legacy_read_only"):', self.source)

    def test_scheduled_price_changes_respect_apples_two_day_minimum(self):
        self.assertNotIn("timedelta(days=1)", self.source)
        self.assertGreaterEqual(self.source.count("timedelta(days=2)"), 2)


if __name__ == "__main__":
    unittest.main()
