import importlib.util
import inspect
import pathlib
import sys
import unittest
from datetime import date
from decimal import Decimal
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "asc_configure_credit_store.py"
SPEC = importlib.util.spec_from_file_location("asc_credit_store", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CreditStoreConfigurationTests(unittest.TestCase):
    @staticmethod
    def price_schedule(*rows):
        data = []
        included = []
        for index, (price, start, end) in enumerate(rows):
            row_id = f"price-{index}"
            point_id = f"point-{index}"
            data.append({
                "type": "inAppPurchasePrices",
                "id": row_id,
                "attributes": {"startDate": start, "endDate": end},
                "relationships": {
                    "inAppPurchasePricePoint": {
                        "data": {
                            "type": "inAppPurchasePricePoints",
                            "id": point_id,
                        }
                    }
                },
            })
            included.append({
                "type": "inAppPurchasePricePoints",
                "id": point_id,
                "attributes": {"customerPrice": str(price)},
            })
        return {"data": data, "included": included}

    def test_app_store_request_retries_transient_network_timeout(self):
        class FakeRequestException(Exception):
            pass

        class FakeResponse:
            status_code = 200
            url = "https://api.appstoreconnect.apple.com/v1/test"
            text = '{"data":[]}'

            @staticmethod
            def json():
                return {"data": []}

        class FakeRequests:
            class exceptions:
                RequestException = FakeRequestException

            def __init__(self):
                self.calls = 0

            def request(self, *args, **kwargs):
                self.calls += 1
                if self.calls == 1:
                    raise FakeRequestException("read timeout")
                return FakeResponse()

        api = object.__new__(MODULE.AppStoreConnect)
        api.requests = FakeRequests()
        api.headers = {"Authorization": "Bearer test"}

        with mock.patch.object(MODULE.time, "sleep") as sleep:
            self.assertEqual(api.request("GET", "/v1/test"), {"data": []})

        self.assertEqual(api.requests.calls, 2)
        sleep.assert_called_once()

    def test_catalog_has_exactly_three_consumable_credit_packs(self):
        self.assertEqual(
            [pack.product_id for pack in MODULE.CREDIT_PACKS],
            [
                "com.x5studio.app.credits.1000",
                "com.x5studio.app.credits.2000",
                "com.x5studio.app.credits.5000",
            ],
        )
        self.assertEqual(
            [(pack.credits, pack.price_kaz) for pack in MODULE.CREDIT_PACKS],
            [
                (1_000, Decimal("1000")),
                (2_000, Decimal("2000")),
                (5_000, Decimal("5000")),
            ],
        )

    def test_create_payload_marks_pack_as_consumable(self):
        payload = MODULE.build_iap_create_payload("app-1", MODULE.CREDIT_PACKS[0])
        data = payload["data"]
        self.assertEqual(data["type"], "inAppPurchases")
        self.assertEqual(data["attributes"]["inAppPurchaseType"], "CONSUMABLE")
        self.assertNotIn("availableInAllTerritories", data["attributes"])
        self.assertEqual(data["relationships"]["app"]["data"]["id"], "app-1")

    def test_availability_payload_creates_kaz_only(self):
        create_payload = MODULE.build_availability_payload("iap-1")
        create_data = create_payload["data"]
        self.assertNotIn("id", create_data)
        self.assertEqual(
            create_data["relationships"]["availableTerritories"]["data"],
            [{"type": "territories", "id": "KAZ"}],
        )

    def test_existing_kaz_only_availability_is_kept_without_update(self):
        class FakeAPI:
            def __init__(self):
                self.calls = []

            def request(self, method, path, **kwargs):
                self.calls.append((method, path, kwargs))
                return {
                    "data": {
                        "type": "inAppPurchaseAvailabilities",
                        "id": "availability-1",
                        "attributes": {"availableInNewTerritories": False},
                    },
                    "included": [{"type": "territories", "id": "KAZ"}],
                }

        api = FakeAPI()
        MODULE.ensure_availability(api, "iap-1")
        self.assertEqual([call[0] for call in api.calls], ["GET"])

    def test_existing_wrong_availability_fails_instead_of_unsupported_patch(self):
        class FakeAPI:
            def request(self, method, path, **kwargs):
                return {
                    "data": {
                        "type": "inAppPurchaseAvailabilities",
                        "id": "availability-1",
                        "attributes": {"availableInNewTerritories": True},
                    },
                    "included": [
                        {"type": "territories", "id": "KAZ"},
                        {"type": "territories", "id": "USA"},
                    ],
                }

        with self.assertRaisesRegex(RuntimeError, "cannot be updated"):
            MODULE.ensure_availability(FakeAPI(), "iap-1")

    def test_review_screenshot_reservation_targets_v2_purchase(self):
        payload = MODULE.review_screenshot_reservation_payload(
            "iap-1", "store.png", 123
        )
        data = payload["data"]
        self.assertEqual(data["type"], "inAppPurchaseAppStoreReviewScreenshots")
        self.assertEqual(data["attributes"], {"fileName": "store.png", "fileSize": 123})
        self.assertEqual(
            data["relationships"]["inAppPurchaseV2"]["data"],
            {"type": "inAppPurchases", "id": "iap-1"},
        )

    def test_price_schedule_uses_kaz_base_and_selected_price_point(self):
        payload = MODULE.build_price_schedule_payload("iap-1", "point-1000")
        relationships = payload["data"]["relationships"]
        self.assertEqual(relationships["baseTerritory"]["data"]["id"], "KAZ")
        included = payload["included"][0]
        self.assertTrue(included["id"].startswith("${"))
        self.assertTrue(included["id"].endswith("}"))
        self.assertEqual(
            relationships["manualPrices"]["data"][0]["id"], included["id"]
        )
        self.assertIsNone(included["attributes"]["startDate"])
        self.assertEqual(
            included["relationships"]["inAppPurchasePricePoint"]["data"]["id"],
            "point-1000",
        )

    def test_active_price_ignores_history_and_future_rows(self):
        schedule = self.price_schedule(
            (5000, None, "2026-08-01"),
            (1000, "2026-08-01", "2026-10-01"),
            (8000, "2026-10-01", None),
        )

        row, price = MODULE.active_manual_price(
            schedule,
            on_date=date(2026, 9, 1),
        )

        self.assertEqual(row["id"], "price-1")
        self.assertEqual(price, Decimal("1000"))

    def test_price_end_date_is_the_first_inactive_day(self):
        schedule = self.price_schedule(
            (1000, None, "2026-09-01"),
            (2000, "2026-09-01", None),
        )

        row, price = MODULE.active_manual_price(
            schedule,
            on_date=date(2026, 9, 1),
        )

        self.assertEqual(row["id"], "price-1")
        self.assertEqual(price, Decimal("2000"))

    def test_multiple_active_prices_fail_closed(self):
        schedule = self.price_schedule(
            (1000, None, None),
            (5000, None, None),
        )

        with self.assertRaisesRegex(RuntimeError, "exactly one active"):
            MODULE.active_manual_price(
                schedule,
                on_date=date(2026, 9, 1),
            )

    def test_configurator_rejects_desired_price_only_in_history(self):
        historical_and_wrong_active = self.price_schedule(
            (1000, None, "2020-01-01"),
            (5000, "2020-01-01", None),
        )

        class FakeAPI:
            @staticmethod
            def list_all(path):
                return [{
                    "type": "inAppPurchasePricePoints",
                    "id": "desired-1000",
                    "attributes": {"customerPrice": "1000"},
                }]

            @staticmethod
            def request(method, path, **kwargs):
                return historical_and_wrong_active

        with self.assertRaisesRegex(RuntimeError, "active KAZ price is 5000"):
            MODULE.ensure_initial_price(FakeAPI(), "iap-1", Decimal("1000"))

    def test_localizations_are_listed_through_the_v2_purchase_relationship(self):
        source = inspect.getsource(MODULE.configure)
        self.assertIn(
            "/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=200",
            source,
        )

    def test_active_localization_is_not_patched(self):
        class FakeAPI:
            def __init__(self):
                self.calls = []

            def request(self, method, path, **kwargs):
                self.calls.append((method, path, kwargs))
                raise AssertionError("ACTIVE localization must stay immutable")

        api = FakeAPI()
        MODULE.ensure_localization(
            api,
            "iap-1",
            [{
                "id": "loc-1",
                "attributes": {"locale": "ru", "state": "ACTIVE"},
            }],
            "ru",
            "Пакет",
            "Описание",
        )
        self.assertEqual(api.calls, [])

    def test_immutable_active_localization_conflict_is_an_audited_noop(self):
        class FakeAPI:
            def request(self, method, path, **kwargs):
                raise RuntimeError(
                    "HTTP 409: ENTITY_ERROR.ATTRIBUTE.INVALID.UNMODIFIABLE: "
                    "Cannot edit InAppPurchaseLocalization when it is in ACTIVE state"
                )

        MODULE.ensure_localization(
            FakeAPI(),
            "iap-1",
            [{"id": "loc-1", "attributes": {"locale": "ru"}}],
            "ru",
            "Пакет",
            "Описание",
        )

    def test_other_localization_patch_failures_are_not_hidden(self):
        class FakeAPI:
            def request(self, method, path, **kwargs):
                raise RuntimeError("HTTP 409: unrelated conflict")

        with self.assertRaisesRegex(RuntimeError, "unrelated conflict"):
            MODULE.ensure_localization(
                FakeAPI(),
                "iap-1",
                [{"id": "loc-1", "attributes": {"locale": "ru"}}],
                "ru",
                "Пакет",
                "Описание",
            )


if __name__ == "__main__":
    unittest.main()
