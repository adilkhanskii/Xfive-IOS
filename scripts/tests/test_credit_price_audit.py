from pathlib import Path
import unittest
from datetime import date
from unittest.mock import patch
from scripts.asc_audit_credit_prices import audit, ReadOnlyAppStoreConnect
from scripts.asc_configure_credit_store import AppStoreConnect, CREDIT_PACKS

ROOT = Path(__file__).resolve().parents[2]


class FakeApple:
    def __init__(self, wrong_price=False, missing=False):
        self.wrong_price = wrong_price
        self.missing = missing

    def list_all(self, path):
        return [{"id": str(p.credits), "attributes": {"productId": p.product_id, "inAppPurchaseType": "CONSUMABLE", "state": "APPROVED"}}
                for p in (CREDIT_PACKS[:2] if self.missing else CREDIT_PACKS)]

    def request(self, method, path):
        assert method == "GET"
        if path.startswith("/v1/apps?"):
            return {"data": [{"id": "synthetic-app"}]}
        credit = path.split("/inAppPurchasePriceSchedules/")[1].split("/")[0]
        return {"data": [{"id": "row", "attributes": {"startDate": None, "endDate": None},
                          "relationships": {"inAppPurchasePricePoint": {"data": {"id": "point"}}}}],
                "included": [{"id": "point", "type": "inAppPurchasePricePoints", "attributes": {"customerPrice": "5000" if self.wrong_price else credit}}]}


class CreditAuditWorkflowTests(unittest.TestCase):
    def test_three_different_current_prices(self):
        result = audit(FakeApple(), date(2026, 9, 7))
        self.assertEqual([r["price"] for r in result["rows"]], ["1000", "2000", "5000"])

    def test_wrong_price_is_not_silently_changed(self):
        with self.assertRaisesRegex(RuntimeError, "current 5000 KZT, expected 1000"):
            audit(FakeApple(wrong_price=True))

    def test_missing_product_is_not_created(self):
        with self.assertRaisesRegex(RuntimeError, "Missing or invalid"):
            audit(FakeApple(missing=True))

    def test_write_methods_refused_before_network(self):
        api = object.__new__(ReadOnlyAppStoreConnect)
        with patch.object(AppStoreConnect, "request") as network:
            for method in ("POST", "PUT", "PATCH", "DELETE"):
                with self.assertRaisesRegex(RuntimeError, "refuses mutations"):
                    api.request(method, "/anything")
            with self.assertRaisesRegex(RuntimeError, "refuses mutations"):
                api.request("GET", "/anything", payload={})
            network.assert_not_called()

    def test_audit_option_cannot_run_configuration_mutations(self):
        text = (ROOT / ".github/workflows/asc-configure-credit-store.yml").read_text()
        for label in ("Configure consumable credit packs", "Configure App Store server notifications"):
            block = text.split(f"- name: {label}")[1].split("- name:")[0]
            self.assertIn("if: github.event_name != 'workflow_dispatch' || inputs.credit_review_action == 'configure'", block)
        self.assertIn("python -m scripts.asc_audit_credit_prices", text)


if __name__ == "__main__":
    unittest.main()
