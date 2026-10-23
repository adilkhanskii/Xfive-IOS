import importlib.util
import pathlib
import unittest


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "asc_configure_server_notifications.py"
)


def load_script():
    spec = importlib.util.spec_from_file_location(
        "asc_configure_server_notifications", SCRIPT_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ConfigureServerNotificationsTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script()

    def test_builds_v2_urls_for_both_environments(self):
        payload = self.module.build_app_update_payload(
            "app-123", self.module.DEFAULT_ENDPOINT
        )

        self.assertEqual(payload["data"]["type"], "apps")
        self.assertEqual(payload["data"]["id"], "app-123")
        attributes = payload["data"]["attributes"]
        self.assertEqual(
            attributes["subscriptionStatusUrl"], self.module.DEFAULT_ENDPOINT
        )
        self.assertEqual(
            attributes["subscriptionStatusUrlForSandbox"],
            self.module.DEFAULT_ENDPOINT,
        )
        self.assertEqual(attributes["subscriptionStatusUrlVersion"], "V2")
        self.assertEqual(
            attributes["subscriptionStatusUrlVersionForSandbox"], "V2"
        )

    def test_rejects_non_https_or_unexpected_endpoint_shape(self):
        invalid = (
            "http://example.com/hook",
            "https://example.com/hook?token=secret",
            "https://example.com/hook#fragment",
            "https://user:pass@example.com/hook",
            "https://example.com/",
        )

        for endpoint in invalid:
            with self.subTest(endpoint=endpoint):
                with self.assertRaises(ValueError):
                    self.module.normalize_endpoint(endpoint)

    def test_accepts_and_normalizes_https_endpoint(self):
        self.assertEqual(
            self.module.normalize_endpoint(
                "  https://example.com/functions/v1/apple-hook/  "
            ),
            "https://example.com/functions/v1/apple-hook",
        )

    def test_readback_requires_exact_urls_and_v2(self):
        endpoint = self.module.DEFAULT_ENDPOINT
        exact = {
            "subscriptionStatusUrl": endpoint,
            "subscriptionStatusUrlForSandbox": endpoint,
            "subscriptionStatusUrlVersion": "V2",
            "subscriptionStatusUrlVersionForSandbox": "V2",
        }
        self.assertTrue(self.module.readback_matches(exact, endpoint))

        for key in exact:
            changed = dict(exact)
            changed[key] = None
            with self.subTest(key=key):
                self.assertFalse(
                    self.module.readback_matches(changed, endpoint)
                )


if __name__ == "__main__":
    unittest.main()
