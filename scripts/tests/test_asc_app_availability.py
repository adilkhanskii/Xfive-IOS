from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "asc_app_availability.py"
SPEC = importlib.util.spec_from_file_location("asc_app_availability", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class AppAvailabilityTests(unittest.TestCase):
    def test_payload_is_narrow_and_disables_only_requested_territory(self) -> None:
        self.assertEqual(
            MODULE.territory_availability_patch("territory-id"),
            {
                "data": {
                    "type": "territoryAvailabilities",
                    "id": "territory-id",
                    "attributes": {"available": False},
                }
            },
        )

    def test_exclude_china_requires_exact_confirmation(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "exact confirmation"):
            MODULE.exclude_china(Mock(), "app-id", "yes")

    def test_load_availability_uses_relationship_territory_id(self) -> None:
        api = Mock()
        api.request.return_value = {
            "data": {
                "type": "appAvailabilities",
                "id": "availability-id",
                "attributes": {"availableInNewTerritories": True},
            }
        }
        api.list_all.return_value = [
            {
                "type": "territoryAvailabilities",
                "id": "chn-resource",
                "attributes": {"available": True},
                "relationships": {
                    "territory": {"data": {"type": "territories", "id": "CHN"}}
                },
            },
            {
                "type": "territoryAvailabilities",
                "id": "kaz-resource",
                "attributes": {"available": True},
                "relationships": {
                    "territory": {"data": {"type": "territories", "id": "KAZ"}}
                },
            },
        ]

        availability, territories = MODULE.load_availability(api, "app-id")

        self.assertEqual(availability["id"], "availability-id")
        self.assertEqual(
            [(row.territory_id, row.available) for row in territories],
            [("CHN", True), ("KAZ", True)],
        )
        api.request.assert_called_once_with(
            "GET", "/v1/apps/app-id/appAvailabilityV2"
        )

    def test_exclude_china_is_idempotent_and_preserves_other_territories(self) -> None:
        api = Mock()
        before_availability = {
            "id": "availability-id",
            "attributes": {"availableInNewTerritories": True},
        }
        after_availability = {
            "id": "availability-id",
            "attributes": {"availableInNewTerritories": False},
        }
        before = [
            MODULE.TerritoryState("chn-resource", "CHN", True),
            MODULE.TerritoryState("kaz-resource", "KAZ", True),
        ]
        after = [
            MODULE.TerritoryState("chn-resource", "CHN", False),
            MODULE.TerritoryState("kaz-resource", "KAZ", True),
        ]
        with patch.object(
            MODULE,
            "load_availability",
            side_effect=[(before_availability, before), (after_availability, after)],
        ):
            MODULE.exclude_china(
                api, "app-id", MODULE.MUTATION_CONFIRMATION
            )

        patch_calls = [call for call in api.request.call_args_list if call.args[0] == "PATCH"]
        self.assertEqual(len(patch_calls), 1)
        self.assertEqual(patch_calls[0].args[1], "/v1/territoryAvailabilities/chn-resource")


if __name__ == "__main__":
    unittest.main()
