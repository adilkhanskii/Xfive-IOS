import argparse
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = spec_from_file_location("kaspi_activate", ROOT / "scripts" / "kaspi_activate.py")
assert SPEC and SPEC.loader
KASPI = module_from_spec(SPEC)
SPEC.loader.exec_module(KASPI)


def args(**overrides):
    values = {
        "service_name": "x5marketing",
        "service_id": "12345",
        "account_parameter_id": "account",
        "callback_url": KASPI.DEFAULT_CALLBACK_URL,
        "enable": False,
        "confirmed_by_kaspi": False,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class KaspiActivationTests(unittest.TestCase):
    def test_staging_keeps_customer_orders_disabled(self):
        payload = KASPI.build_payload(args())
        self.assertFalse(payload["p_enabled"])
        self.assertEqual(payload["p_service_name"], "x5marketing")
        self.assertEqual(payload["p_provider_callback_url"], KASPI.DEFAULT_CALLBACK_URL)

    def test_live_enable_requires_kaspi_callback_confirmation(self):
        with self.assertRaisesRegex(ValueError, "confirmed-by-kaspi"):
            KASPI.build_payload(args(enable=True))

        payload = KASPI.build_payload(
            args(enable=True, confirmed_by_kaspi=True)
        )
        self.assertTrue(payload["p_enabled"])

    def test_identifiers_are_strict_and_cannot_inject_a_url(self):
        with self.assertRaises(ValueError):
            KASPI.build_payload(args(service_name="https://example.test/pay"))


if __name__ == "__main__":
    unittest.main()
