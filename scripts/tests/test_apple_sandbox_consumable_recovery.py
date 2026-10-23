import base64
import contextlib
import io
import json
import unittest
from pathlib import Path

from scripts.apple_sandbox_consumable_recovery import (
    FIXED_WEBHOOK_URL,
    RECOVERY_TARGETS,
    build_recovery_plan,
    deliver_notification,
    match_notification,
    normalize_quantity,
    recover_purchases,
    select_one_unique_match,
)


def fake_jws(payload):
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"header.{encoded}.signature"


def notification(
    target,
    *,
    app_account_token=None,
    product_id=None,
    bundle_id="com.x5studio.app",
    data_environment="Sandbox",
    transaction_environment="Sandbox",
    notification_type="ONE_TIME_CHARGE",
    subtype=None,
    transaction_type="Consumable",
    ownership="PURCHASED",
    quantity_marker="one",
    purchase_date=None,
    transaction_id="2000000999999999",
    original_transaction_id=None,
):
    transaction = {
        "appAccountToken": app_account_token or target.app_account_token,
        "productId": product_id or target.product_ids[0],
        "bundleId": bundle_id,
        "environment": transaction_environment,
        "type": transaction_type,
        "inAppOwnershipType": ownership,
        "transactionId": transaction_id,
        "originalTransactionId": original_transaction_id or transaction_id,
        "purchaseDate": purchase_date or target.start_ms + 60_000,
    }
    if quantity_marker == "one":
        transaction["quantity"] = 1
    elif quantity_marker == "null":
        transaction["quantity"] = None
    elif quantity_marker != "omitted":
        transaction["quantity"] = quantity_marker

    outer = {
        "notificationType": notification_type,
        "data": {
            "bundleId": bundle_id,
            "environment": data_environment,
            "signedTransactionInfo": fake_jws(transaction),
        },
    }
    if subtype is not None:
        outer["subtype"] = subtype
    return fake_jws(outer)


class FakeResponse:
    def __init__(self, status_code=200, payload=None):
        self.status_code = status_code
        self._payload = payload or {"status": "applied"}

    def json(self):
        return self._payload


class AppleSandboxConsumableRecoveryTests(unittest.TestCase):
    def test_target_is_only_the_one_apple_confirmed_adilkhan_consumable(self):
        self.assertEqual(
            [target.label for target in RECOVERY_TARGETS],
            ["adilkhan_credits_2000"],
        )
        self.assertEqual(
            [target.product_ids for target in RECOVERY_TARGETS],
            [("com.x5studio.app.credits.2000",)],
        )
        self.assertEqual(
            [(target.start_ms, target.end_ms) for target in RECOVERY_TARGETS],
            [(1784533500000, 1784535000000)],
        )
        self.assertEqual(
            {target.app_account_token for target in RECOVERY_TARGETS},
            {"eee55a08-18d1-46e3-a303-1411d1bb9333"},
        )
        self.assertNotIn("dossymkhan", " ".join(t.label for t in RECOVERY_TARGETS))
        self.assertEqual(
            FIXED_WEBHOOK_URL,
            "https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/app-store-notifications",
        )

    def test_quantity_accepts_only_omitted_null_or_integer_one(self):
        self.assertEqual(normalize_quantity({}), 1)
        self.assertEqual(normalize_quantity({"quantity": None}), 1)
        self.assertEqual(normalize_quantity({"quantity": 1}), 1)
        for value in (0, 2, -1, "1", 1.0, True, False):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    normalize_quantity({"quantity": value})

    def test_matches_exact_sandbox_consumable_for_each_target(self):
        for target in RECOVERY_TARGETS:
            for quantity in ("omitted", "null", "one"):
                with self.subTest(target=target.label, quantity=quantity):
                    signed_payload = notification(target, quantity_marker=quantity)
                    match = match_notification(signed_payload, target)
                    self.assertIsNotNone(match)
                    self.assertEqual(match.signed_payload, signed_payload)
                    self.assertEqual(match.quantity, 1)

    def test_rejects_every_routing_or_transaction_mismatch(self):
        target = RECOVERY_TARGETS[0]
        rejected = [
            notification(target, app_account_token="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            notification(target, product_id="com.x5studio.app.credits.1000"),
            notification(target, product_id="com.x5studio.app.credits.5000"),
            notification(target, bundle_id="com.example.other"),
            notification(target, data_environment="Production"),
            notification(target, transaction_environment="Production"),
            notification(target, notification_type="SUBSCRIBED"),
            notification(target, subtype="INITIAL_BUY"),
            notification(target, transaction_type="Non-Consumable"),
            notification(target, ownership="FAMILY_SHARED"),
            notification(target, quantity_marker=2),
            notification(target, quantity_marker="1"),
            notification(target, purchase_date=target.start_ms - 1),
            notification(target, purchase_date=target.end_ms + 1),
            notification(target, original_transaction_id="2000000888888888"),
            "not-a-jws",
        ]
        for signed_payload in rejected:
            with self.subTest(payload_number=rejected.index(signed_payload)):
                self.assertIsNone(match_notification(signed_payload, target))

    def test_requires_exactly_one_unique_signed_payload_per_target(self):
        target = RECOVERY_TARGETS[0]
        exact = notification(target)
        duplicate = exact
        second = notification(target, transaction_id="2000000777777777")

        selected = select_one_unique_match(
            [{"signedPayload": exact}, {"signedPayload": duplicate}], target
        )
        self.assertEqual(selected.signed_payload, exact)
        with self.assertRaisesRegex(RuntimeError, "expected_one_unique_match"):
            select_one_unique_match([], target)
        with self.assertRaisesRegex(RuntimeError, "expected_one_unique_match"):
            select_one_unique_match(
                [{"signedPayload": exact}, {"signedPayload": second}], target
            )

    def test_builds_the_complete_plan_from_only_the_fixed_window(self):
        calls = []

        def fetcher(start_ms, end_ms):
            calls.append((start_ms, end_ms))
            target = next(
                item
                for item in RECOVERY_TARGETS
                if (item.start_ms, item.end_ms) == (start_ms, end_ms)
            )
            return [{"signedPayload": notification(target)}]

        plan = build_recovery_plan(fetcher=fetcher)

        self.assertEqual(
            calls,
            [(item.start_ms, item.end_ms) for item in RECOVERY_TARGETS],
        )
        self.assertEqual(
            [item.target.label for item in plan],
            ["adilkhan_credits_2000"],
        )

    def test_never_posts_if_target_is_missing_or_ambiguous(self):
        posted = []

        def fetcher(start_ms, end_ms):
            return []

        with self.assertRaisesRegex(RuntimeError, "expected_one_unique_match"):
            recover_purchases(fetcher=fetcher, post=lambda *args, **kwargs: posted.append(args))
        self.assertEqual(posted, [])

    def test_posts_only_the_original_payload_to_the_fixed_webhook(self):
        target = RECOVERY_TARGETS[0]
        signed_payload = notification(target)
        match = match_notification(signed_payload, target)
        calls = []

        def post(url, **kwargs):
            calls.append((url, kwargs))
            return FakeResponse(payload={"status": "already_applied"})

        outcome = deliver_notification(match, post=post)

        self.assertEqual(outcome, (200, "already_applied"))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], FIXED_WEBHOOK_URL)
        self.assertEqual(calls[0][1]["json"], {"signedPayload": signed_payload})
        self.assertEqual(calls[0][1]["headers"], {"Content-Type": "application/json"})

    def test_all_deliveries_must_be_applied_or_already_applied(self):
        histories = {}
        for target in RECOVERY_TARGETS:
            histories[(target.start_ms, target.end_ms)] = [
                {"signedPayload": notification(target)}
            ]

        def fetcher(start_ms, end_ms):
            return histories[(start_ms, end_ms)]

        responses = iter([FakeResponse(payload={"status": "applied"})])
        outcomes = recover_purchases(
            fetcher=fetcher,
            post=lambda *args, **kwargs: next(responses),
        )
        self.assertEqual(
            outcomes,
            [("adilkhan_credits_2000", 200, "applied")],
        )

        for response in (
            FakeResponse(payload={"status": "ignored"}),
            FakeResponse(status_code=500, payload={"status": "applied"}),
            FakeResponse(payload={"error": "contains-sensitive-details"}),
        ):
            with self.subTest(status=response.status_code):
                with self.assertRaisesRegex(RuntimeError, "delivery_not_applied") as raised:
                    recover_purchases(
                        fetcher=fetcher,
                        post=lambda *args, response=response, **kwargs: response,
                    )
                self.assertNotIn("contains-sensitive-details", str(raised.exception))

    def test_console_output_never_contains_sensitive_purchase_identifiers(self):
        histories = {}
        payloads = []
        transaction_ids = []
        for index, target in enumerate(RECOVERY_TARGETS, start=1):
            transaction_id = f"200000099999999{index}"
            signed_payload = notification(target, transaction_id=transaction_id)
            histories[(target.start_ms, target.end_ms)] = [
                {"signedPayload": signed_payload}
            ]
            payloads.append(signed_payload)
            transaction_ids.append(transaction_id)

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            recover_purchases(
                fetcher=lambda start, end: histories[(start, end)],
                post=lambda *args, **kwargs: FakeResponse(),
                emit_progress=True,
            )
        rendered = output.getvalue()
        for target in RECOVERY_TARGETS:
            self.assertNotIn(target.app_account_token, rendered)
        for secret in payloads + transaction_ids:
            self.assertNotIn(secret, rendered)
        self.assertIn("target=adilkhan_credits_2000", rendered)


class AppleSandboxConsumableRecoveryWorkflowTests(unittest.TestCase):
    def test_manual_workflow_is_narrow_and_has_minimal_permissions(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (
            root
            / ".github"
            / "workflows"
            / "asc-sandbox-consumable-recovery.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("inputs:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("secrets.IAP_API_KEY_ID", workflow)
        self.assertIn("secrets.IAP_API_ISSUER_ID", workflow)
        self.assertIn("secrets.IAP_API_KEY_BASE64", workflow)
        self.assertIn(
            "python -m scripts.apple_sandbox_consumable_recovery",
            workflow,
        )
        self.assertIn(
            "python -m unittest scripts.tests.test_apple_sandbox_consumable_recovery",
            workflow,
        )
        forbidden = (
            "TARGET_APP_ACCOUNT_TOKEN",
            "HISTORY_START_MS",
            "HISTORY_END_MS",
            "APP_STORE_NOTIFICATIONS_URL",
            "dossymkhan",
            "upload-artifact",
            "supabase",
            "psql",
            "curl ",
        )
        for value in forbidden:
            self.assertNotIn(value, workflow)


if __name__ == "__main__":
    unittest.main()
