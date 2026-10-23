"""Wiring regressions. Swift tests separately exercise callback behavior."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class IAPAcceptanceRecoveryContracts(unittest.TestCase):
    def test_delivery_notifies_profile_without_recursive_store_replay(self):
        service = (ROOT / "X5/Services/IAPService.swift").read_text(encoding="utf-8")
        app = (ROOT / "X5/X5App.swift").read_text(encoding="utf-8")
        self.assertIn("didApply:", service)
        self.assertIn(".x5DidUpdateStoreEntitlements", service)
        self.assertIn(".x5DidUpdateStoreEntitlements", app)
        self.assertIn("await refreshProfileAfterStoreDelivery", app)

    def test_signed_account_token_rejection_is_not_temporary_failure(self):
        service = (ROOT / "X5/Services/IAPService.swift").read_text(encoding="utf-8")
        self.assertIn('serverError == "account_token_mismatch"', service)

    def test_cancelled_badge_purchase_does_not_invent_server_failure(self):
        view = (ROOT / "X5/Views/VerifiedBadgeView.swift").read_text(encoding="utf-8")
        self.assertNotRegex(view, r'errorText\s*=\s*iap\.lastError\s*\?\?\s*loc\.t\("verified_purchase_failed"\)')
        self.assertIn(".onChange(of: iap.lastError)", view)


if __name__ == "__main__":
    unittest.main()
