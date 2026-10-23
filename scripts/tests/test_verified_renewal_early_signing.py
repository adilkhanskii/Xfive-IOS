"""Wiring regression for early-billed App Store renewals (2026-10-02 incident).

Apple bills an auto-renewal up to 24 hours before the period ends and signs it
then, while purchaseDate is the new period start. Isolated PostgreSQL proof:
supabase/tests/20261002_verified_renewal_early_signing_test.sql.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261002150000_verified_renewal_early_signing.sql"
PREFLIGHT = ROOT / "supabase/deploy/20261002_verified_renewal_early_signing_preflight.sql"
FUNCTIONS = ROOT / "supabase/functions"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


class VerifiedRenewalEarlySigning(unittest.TestCase):
    def test_migration_widens_only_the_renewal_lead(self):
        source = read(MIGRATION)
        self.assertTrue(source.startswith("-- ") and "\nbegin;\n" in source)
        self.assertTrue(source.rstrip().endswith("commit;"))
        strict = source[source.index("FUNCTION public.x5_apply_verified_app_store_transaction_signed_date_strict_inte("):]
        strict = strict[: strict.index("$function$;")]
        self.assertIn("p_signed_date < p_purchase_date - interval '25 hours'", strict)
        self.assertIn("p_purchase_date > clock_timestamp() + interval '25 hours'", strict)
        self.assertIn("p_signed_date > clock_timestamp() + interval '10 minutes'", strict)
        self.assertNotIn("interval '5 minutes'", strict)

        badge = source[source.index("FUNCTION public.x5_apply_verified_app_store_badge_lifecycle_internal("):]
        badge = badge[: badge.index("$function$;")]
        for rule in (
            "p_transaction_signed_date < p_purchase_date - interval '25 hours'",
            "p_renewal_signed_date < p_purchase_date - interval '25 hours'",
            "p_purchase_date > clock_timestamp() + interval '25 hours'",
            "p_transaction_signed_date > clock_timestamp() + interval '10 minutes'",
            "p_transaction_signed_date - interval '5 minutes'",
            "p_renewal_signed_date - interval '5 minutes'",
        ):
            self.assertIn(rule, badge)
        self.assertIn("SECURITY DEFINER", badge)
        self.assertIn("SET search_path TO ''", badge)

    def test_constraints_are_replaced_then_validated_and_grants_kept(self):
        source = read(MIGRATION)
        for table, constraint in (
            ("app_store_transactions", "app_store_transactions_dates_valid"),
            ("app_store_verified_lifecycle_events", "app_store_verified_lifecycle_events_dates"),
        ):
            self.assertIn(f"drop constraint if exists {constraint}", source)
            self.assertRegex(source, rf"add constraint {constraint}\s+check \([\s\S]+?\) not valid;")
            self.assertIn(f"alter table public.{table}\n  validate constraint {constraint};", source)
        self.assertEqual(source.count("from public, anon, authenticated, service_role;"), 2)
        self.assertNotRegex(source, r"(?im)^\s*grant\s")

    def test_preflight_pins_audited_and_fixed_bodies(self):
        source = read(PREFLIGHT)
        for digest in (
            "05a3dbdb4b4e32747ac4bc88096dcdca",
            "2bd744459c2965fa2ad1fc8eed9574ec",
            "f4be4aecb4835df2de6cc97cfdf79f00",
            "88757d7e6b72a93dc4a6b37d3467138f",
        ):
            self.assertIn(digest, source)
        self.assertNotRegex(source, r"(?i)\b(insert|update|delete|alter|create|drop|grant|revoke)\b\s")

    def test_edge_validation_uses_the_same_window(self):
        for name in ("app-store-notifications", "verify-app-store-transaction"):
            source = read(FUNCTIONS / name / "validation.ts")
            self.assertIn("export const MAX_RENEWAL_EARLY_SIGNING_MS = 25 * 60 * 60_000;", source)
            self.assertIn("const MAX_CLOCK_SKEW_MS = 5 * 60_000;", source)
        notifications = read(FUNCTIONS / "app-store-notifications/validation.ts")
        self.assertEqual(len(re.findall(r"purchaseDateMs - MAX_RENEWAL_EARLY_SIGNING_MS", notifications)), 2)


if __name__ == "__main__":
    unittest.main()
