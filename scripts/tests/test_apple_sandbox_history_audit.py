import base64
import json
import unittest
from pathlib import Path

from scripts.apple_sandbox_history_audit import (
    AUDIT_WINDOWS,
    SANDBOX_HISTORY_URL,
    audit_sandbox_history,
    fetch_history,
    safe_notification_summary,
)


def fake_jws(payload):
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"header.{encoded}.signature"


def notification(
    *,
    app_account_token,
    product_id,
    purchase_date,
    notification_type,
    subtype=None,
    environment="Sandbox",
    bundle_id="com.x5studio.app",
    transaction_id="2000000999999999",
):
    transaction = fake_jws(
        {
            "appAccountToken": app_account_token,
            "productId": product_id,
            "bundleId": bundle_id,
            "environment": environment,
            "type": (
                "Auto-Renewable Subscription"
                if notification_type == "SUBSCRIBED"
                else "Consumable"
            ),
            "inAppOwnershipType": "PURCHASED",
            "quantity": 1,
            "transactionId": transaction_id,
            "originalTransactionId": transaction_id,
            "purchaseDate": purchase_date,
        }
    )
    outer = {
        "notificationType": notification_type,
        "data": {
            "bundleId": bundle_id,
            "environment": environment,
            "signedTransactionInfo": transaction,
        },
    }
    if subtype is not None:
        outer["subtype"] = subtype
    return fake_jws(outer)


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code

    def json(self):
        return self._payload


class AppleSandboxHistoryAuditTests(unittest.TestCase):
    def test_approved_windows_are_fixed_and_narrow_for_both_accounts(self):
        labels = [window.label for window in AUDIT_WINDOWS]
        self.assertEqual(
            labels,
            ["adilkhan_credits_2000", "dossymkhan_lite"],
        )
        self.assertTrue(all(window.end_ms > window.start_ms for window in AUDIT_WINDOWS))
        self.assertTrue(
            all(window.end_ms - window.start_ms <= 60 * 60 * 1000 for window in AUDIT_WINDOWS)
        )

    def test_fetch_history_can_only_call_the_apple_sandbox_endpoint(self):
        calls = []

        def post(url, **kwargs):
            calls.append((url, kwargs))
            return FakeResponse({"notificationHistory": [], "hasMore": False})

        items = fetch_history(
            AUDIT_WINDOWS[0].start_ms,
            AUDIT_WINDOWS[0].end_ms,
            post=post,
            token_factory=lambda: "signed-api-token",
        )

        self.assertEqual(items, [])
        self.assertEqual([call[0] for call in calls], [SANDBOX_HISTORY_URL])
        self.assertEqual(calls[0][1]["json"], {
            "startDate": AUDIT_WINDOWS[0].start_ms,
            "endDate": AUDIT_WINDOWS[0].end_ms,
        })
        self.assertNotIn("signedPayload", calls[0][1]["json"])

    def test_audit_matches_each_account_without_exposing_payment_identifiers(self):
        histories = {}
        for window in AUDIT_WINDOWS:
            histories[(window.start_ms, window.end_ms)] = [
                {
                    "signedPayload": notification(
                        app_account_token=window.app_account_token,
                        product_id=window.product_ids[0],
                        purchase_date=window.start_ms + 60_000,
                        notification_type=window.notification_type,
                        subtype=window.subtype,
                        transaction_id=f"2000000-{window.label}",
                    )
                }
            ]

        def fetcher(start_ms, end_ms):
            return histories[(start_ms, end_ms)]

        report = audit_sandbox_history(fetcher=fetcher, now_ms=1784600000000)

        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["environment"], "Sandbox")
        self.assertEqual(
            [item["exact_matches"] for item in report["windows"]],
            [1] * len(AUDIT_WINDOWS),
        )
        serialized = json.dumps(report, sort_keys=True)
        for window in AUDIT_WINDOWS:
            self.assertNotIn(window.app_account_token, serialized)
            self.assertNotIn(f"2000000-{window.label}", serialized)
        self.assertNotIn("signedPayload", serialized)
        self.assertNotIn("signature", serialized)

    def test_wrong_account_environment_product_or_time_never_matches(self):
        window = AUDIT_WINDOWS[0]
        exact = notification(
            app_account_token=window.app_account_token,
            product_id=window.product_ids[0],
            purchase_date=window.start_ms + 60_000,
            notification_type=window.notification_type,
            subtype=window.subtype,
        )
        rejected = [
            notification(
                app_account_token="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                product_id=window.product_ids[0],
                purchase_date=window.start_ms + 60_000,
                notification_type=window.notification_type,
                subtype=window.subtype,
            ),
            notification(
                app_account_token=window.app_account_token,
                product_id="com.x5studio.app.credits.5000",
                purchase_date=window.start_ms + 60_000,
                notification_type=window.notification_type,
                subtype=window.subtype,
            ),
            notification(
                app_account_token=window.app_account_token,
                product_id=window.product_ids[0],
                purchase_date=window.start_ms + 60_000,
                notification_type=window.notification_type,
                subtype=window.subtype,
                environment="Production",
            ),
            notification(
                app_account_token=window.app_account_token,
                product_id=window.product_ids[0],
                purchase_date=window.start_ms - 1,
                notification_type=window.notification_type,
                subtype=window.subtype,
            ),
        ]

        self.assertTrue(safe_notification_summary(exact, window)["exact_match"])
        self.assertTrue(
            all(not safe_notification_summary(item, window)["exact_match"] for item in rejected)
        )

    def test_malformed_history_is_reported_only_as_a_safe_decode_failure(self):
        summary = safe_notification_summary("not-a-jws", AUDIT_WINDOWS[0])
        self.assertEqual(summary, {"exact_match": False, "decode": "failed"})


class AppleSandboxHistoryWorkflowTests(unittest.TestCase):
    def test_manual_workflow_runs_only_the_safe_auditor_and_uploads_its_report(self):
        repository_root = Path(__file__).resolve().parents[2]
        workflow = (
            repository_root
            / ".github"
            / "workflows"
            / "asc-sandbox-history-audit.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("secrets.IAP_API_KEY_ID", workflow)
        self.assertIn("secrets.IAP_API_ISSUER_ID", workflow)
        self.assertIn("secrets.IAP_API_KEY_BASE64", workflow)
        self.assertIn(
            "python scripts/apple_sandbox_history_audit.py --output",
            workflow,
        )
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2",
            workflow,
        )
        self.assertNotIn("actions/upload-artifact@v4", workflow)
        self.assertIn("apple-sandbox-history-audit.json", workflow)

        forbidden = (
            "apple_notification_replay.py",
            "APP_STORE_NOTIFICATIONS_URL",
            "functions/v1",
            "supabase.co",
            "curl ",
        )
        for value in forbidden:
            self.assertNotIn(value, workflow)


if __name__ == "__main__":
    unittest.main()
