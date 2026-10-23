import unittest
from scripts.apple_transaction_audit import parse_ids, summarize


class TransactionAuditTests(unittest.TestCase):
    def payload(self):
        return dict(bundleId="com.x5studio.app", transactionId="123456789",
                    environment="Production", price=1000000, currency="KZT",
                    appAccountToken="PRIVATE", productId="com.x5studio.app.credits.1000")

    def test_price_uses_milliunits_and_omits_identity(self):
        result = summarize(self.payload(), "123456789")
        self.assertEqual(result["price"], "1000")
        self.assertNotIn("PRIVATE", str(result))
        self.assertNotIn("123456789", str(result))
        self.assertIn("not bank settlement", result["source"])

    def test_rejects_wrong_identity_and_environment(self):
        for field, value in [("bundleId", "other"), ("transactionId", "99999"), ("environment", "Sandbox")]:
            payload = self.payload()
            payload[field] = value
            with self.assertRaises(ValueError):
                summarize(payload, "123456789")

    def test_revocation_and_missing_price_preserved(self):
        payload = self.payload()
        payload.update(price=None, revocationDate=123, revocationReason=1)
        result = summarize(payload, "123456789")
        self.assertIsNone(result["price"])
        self.assertEqual(result["revocation_date_ms"], 123)

    def test_bounded_input_not_url_or_code(self):
        self.assertEqual(parse_ids("12345, 12345,67890"), ["12345", "67890"])
        for value in ["", "../token", "12345?key=x", "12345;echo", ",".join(["12345"] * 11)]:
            with self.assertRaises(ValueError):
                parse_ids(value)


if __name__ == "__main__":
    unittest.main()
