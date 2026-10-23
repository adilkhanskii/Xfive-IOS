import base64
import json
import unittest

from scripts.apple_notification_replay import (
    EXPECTED_PURCHASE_START_MS,
    EXPECTED_PRODUCT_ID,
    decode_jws_payload,
    delivery_applied,
    match_notification,
    matching_notifications,
    safe_notification_summary,
    select_single_notification,
)


USER_ID = "f4e32ce0-ca32-45ad-a63e-cc3b4a526881"
BUNDLE_ID = "com.x5studio.app"


def fake_jws(payload):
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"header.{encoded}.signature"


def notification(
    *,
    user_id=USER_ID,
    product_id=EXPECTED_PRODUCT_ID,
    bundle_id=BUNDLE_ID,
    environment="Production",
    notification_type="SUBSCRIBED",
    subtype="INITIAL_BUY",
    transaction_id="2000000999999999",
    original_transaction_id="2000000999999999",
    purchase_date=EXPECTED_PURCHASE_START_MS + 60_000,
):
    transaction = fake_jws(
        {
            "appAccountToken": user_id,
            "productId": product_id,
            "bundleId": bundle_id,
            "environment": environment,
            "type": "Auto-Renewable Subscription",
            "inAppOwnershipType": "PURCHASED",
            "quantity": 1,
            "transactionId": transaction_id,
            "originalTransactionId": original_transaction_id,
            "purchaseDate": purchase_date,
        }
    )
    return fake_jws(
        {
            "notificationType": notification_type,
            "subtype": subtype,
            "data": {
                "bundleId": bundle_id,
                "environment": environment,
                "signedTransactionInfo": transaction,
            },
        }
    )


class AppleNotificationReplayTests(unittest.TestCase):
    def test_decodes_only_the_jws_payload_segment(self):
        self.assertEqual(decode_jws_payload(fake_jws({"ok": True})), {"ok": True})
        with self.assertRaises(ValueError):
            decode_jws_payload("not-a-jws")

    def test_matches_only_the_exact_production_lite_purchase(self):
        match = match_notification(
            notification(), target_user_id=USER_ID, bundle_id=BUNDLE_ID
        )
        self.assertIsNotNone(match)
        self.assertEqual(match.product_id, EXPECTED_PRODUCT_ID)

        rejected = [
            notification(user_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            notification(product_id="com.x5studio.app.pro.monthly"),
            notification(bundle_id="com.example.other"),
            notification(environment="Sandbox"),
            notification(notification_type="REFUND"),
            notification(notification_type="OFFER_REDEEMED"),
            notification(subtype="RESUBSCRIBE"),
            notification(original_transaction_id="2000000888888888"),
            notification(purchase_date=EXPECTED_PURCHASE_START_MS - 1),
            "invalid",
        ]
        for signed_payload in rejected:
            self.assertIsNone(
                match_notification(
                    signed_payload,
                    target_user_id=USER_ID,
                    bundle_id=BUNDLE_ID,
                )
            )

    def test_filters_history_without_exposing_or_widening_the_match(self):
        exact = notification()
        matches = matching_notifications(
            [
                {"signedPayload": notification(product_id="wrong")},
                {"signedPayload": exact},
                {"notSignedPayload": exact},
            ],
            target_user_id=USER_ID,
            bundle_id=BUNDLE_ID,
        )
        self.assertEqual([item.signed_payload for item in matches], [exact])

    def test_requires_exactly_one_unique_initial_transaction(self):
        exact = match_notification(
            notification(), target_user_id=USER_ID, bundle_id=BUNDLE_ID
        )
        second = match_notification(
            notification(transaction_id="2000000777777777",
                         original_transaction_id="2000000777777777"),
            target_user_id=USER_ID,
            bundle_id=BUNDLE_ID,
        )
        self.assertIsNotNone(exact)
        self.assertIsNotNone(second)
        self.assertEqual(select_single_notification([exact]), exact)
        with self.assertRaisesRegex(RuntimeError, "expected_one_exact_match"):
            select_single_notification([])
        with self.assertRaisesRegex(RuntimeError, "expected_one_exact_match"):
            select_single_notification([exact, second])

    def test_only_applied_webhook_results_are_success(self):
        self.assertTrue(delivery_applied(200, "applied"))
        self.assertTrue(delivery_applied(200, "already_applied"))
        self.assertFalse(delivery_applied(200, "ignored"))
        self.assertFalse(delivery_applied(200, "ignored_stale"))
        self.assertFalse(delivery_applied(500, "applied"))

    def test_safe_summary_exposes_matches_but_not_ids_or_token(self):
        signed_payload = notification()
        summary = safe_notification_summary(
            signed_payload,
            target_user_id=USER_ID,
            bundle_id=BUNDLE_ID,
        )
        self.assertIn("type=SUBSCRIBED", summary)
        self.assertIn("account_match=True", summary)
        self.assertIn("purchase_in_window=True", summary)
        self.assertNotIn(USER_ID, summary)
        self.assertNotIn("2000000999999999", summary)
        self.assertNotIn(signed_payload, summary)


if __name__ == "__main__":
    unittest.main()
