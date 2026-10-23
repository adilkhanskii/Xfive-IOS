from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260813150000_kaspi_credit_payments.sql"
).read_text(encoding="utf-8")
PAYWALL = (ROOT / "X5" / "Views" / "PaywallView.swift").read_text(
    encoding="utf-8"
)
LOCALIZATION = (
    ROOT / "X5" / "Services" / "LocalizationService.swift"
).read_text(encoding="utf-8")
PROVIDER = (
    ROOT / "supabase" / "functions" / "kaspi-pay-provider" / "index.ts"
).read_text(encoding="utf-8")
PROTOCOL = (
    ROOT / "supabase" / "functions" / "kaspi-pay-provider" / "protocol.mjs"
).read_text(encoding="utf-8")


class AppStoreCreditPaymentsTests(unittest.TestCase):
    def test_ios_credit_store_uses_storekit_only(self):
        self.assertIn("import StoreKit", PAYWALL)
        self.assertIn("iap.purchase(productID: pack.productID)", PAYWALL)
        self.assertIn('"method": "app_store_storekit"', PAYWALL)
        self.assertNotIn("confirmationDialog", PAYWALL)
        self.assertNotIn("paymentMethodPack", PAYWALL)
        self.assertNotIn("buyWithKaspi", PAYWALL)
        self.assertNotIn("openURL", PAYWALL)

    def test_ios_binary_contains_no_alternate_credit_checkout(self):
        self.assertFalse(
            (ROOT / "X5" / "Services" / "KaspiCreditPaymentService.swift").exists()
        )
        forbidden_keys = (
            "credit_store_payment_card",
            "credit_store_payment_apple_pay",
            "credit_store_payment_kaspi",
            "credit_store_kaspi_buy",
            "credit_store_kaspi_exact_amount",
        )
        for key in forbidden_keys:
            self.assertNotIn(key, PAYWALL)
            self.assertNotIn(key, LOCALIZATION)

    def test_credit_pack_has_one_direct_purchase_button(self):
        pack_card = PAYWALL.split("private func packCard", 1)[1].split(
            "private func buyViaAppStore", 1
        )[0]
        self.assertEqual(pack_card.count("Button {"), 1)
        self.assertIn("buyViaAppStore(pack)", pack_card)
        self.assertNotIn("payment method", pack_card.lower())

    def test_dormant_server_catalog_never_accepts_client_amounts(self):
        self.assertIn("create_kaspi_credit_payment(p_product_id text)", MIGRATION)
        self.assertIn("constraint kaspi_credit_catalog_match", MIGRATION)
        self.assertNotIn("p_amount_kzt", MIGRATION)

    def test_dormant_provider_callback_is_idempotent_and_service_role_only(self):
        self.assertIn("auth.role() <> 'service_role'", MIGRATION)
        self.assertIn("where txn_id = p_txn_id", MIGRATION)
        self.assertIn("for update", MIGRATION)
        self.assertIn("apply_kaspi_provider_command", PROVIDER)

    def test_dormant_provider_network_is_allowlisted(self):
        self.assertIn("194.187.247.152", PROTOCOL)
        self.assertIn("KASPI_ALLOWED_IPS", PROVIDER)
        self.assertIn("Forbidden", PROVIDER)


if __name__ == "__main__":
    unittest.main()
