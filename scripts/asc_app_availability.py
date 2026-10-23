#!/usr/bin/env python3
"""Audit or exclude Mainland China from X5 App Store availability.

The mutation is deliberately narrow: it marks only the CHN territory
availability as false. Every other territory is left untouched.
"""

from __future__ import annotations

import argparse
import base64
import os
import time
from dataclasses import dataclass
from typing import Any


API_ROOT = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.x5studio.app"
CHINA_TERRITORY = "CHN"
MUTATION_CONFIRMATION = "EXCLUDE_CHN_KEEP_OTHER_TERRITORIES"
TRANSIENT_HTTP_STATUSES = {429, 500, 502, 503, 504}


def territory_availability_patch(territory_availability_id: str) -> dict[str, Any]:
    return {
        "data": {
            "type": "territoryAvailabilities",
            "id": territory_availability_id,
            "attributes": {"available": False},
        }
    }
@dataclass(frozen=True)
class TerritoryState:
    resource_id: str
    territory_id: str
    available: bool


class AppStoreConnect:
    def __init__(self) -> None:
        import jwt
        import requests

        self.requests = requests
        now = int(time.time())
        token = jwt.encode(
            {
                "iss": os.environ["ASC_API_ISSUER_ID"],
                "iat": now,
                "exp": now + 10 * 60,
                "aud": "appstoreconnect-v1",
            },
            base64.b64decode(os.environ["ASC_API_KEY_BASE64"]),
            algorithm="ES256",
            headers={"kid": os.environ["ASC_API_KEY_ID"], "typ": "JWT"},
        )
        self.headers = {"Authorization": f"Bearer {token}"}

    def request(
        self,
        method: str,
        path: str,
        *,
        expected: tuple[int, ...] = (200,),
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = path if path.startswith("http") else f"{API_ROOT}{path}"
        response = None
        for attempt in range(3):
            response = self.requests.request(
                method,
                url,
                headers={
                    **self.headers,
                    **({"Content-Type": "application/json"} if payload else {}),
                },
                json=payload,
                timeout=60,
            )
            if response.status_code not in TRANSIENT_HTTP_STATUSES or attempt == 2:
                break
            time.sleep(2**attempt)
        if response is None or response.status_code not in expected:
            status = response.status_code if response is not None else "no response"
            detail = response.text[:2000] if response is not None else ""
            raise RuntimeError(f"{method} {url} -> HTTP {status}: {detail}")
        return response.json() if response.text else {}

    def list_all(self, path: str) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        next_path: str | None = path
        while next_path:
            page = self.request("GET", next_path)
            rows.extend(page.get("data", []))
            next_path = page.get("links", {}).get("next")
        return rows


def find_app_id(api: AppStoreConnect, bundle_id: str) -> str:
    rows = api.request("GET", f"/v1/apps?filter[bundleId]={bundle_id}").get("data", [])
    if len(rows) != 1:
        raise RuntimeError(f"Expected one app for {bundle_id}, found {len(rows)}")
    return str(rows[0]["id"])


def load_availability(
    api: AppStoreConnect, app_id: str
) -> tuple[dict[str, Any], list[TerritoryState]]:
    availability = None
    availability_errors: list[str] = []
    for path in (
        f"/v1/apps/{app_id}/appAvailabilityV2",
        f"/v1/apps/{app_id}/appAvailability",
        f"/v1/appAvailabilitiesV2?filter[app]={app_id}",
        f"/v1/appAvailabilities?filter[app]={app_id}",
    ):
        try:
            candidate = api.request("GET", path).get("data")
        except RuntimeError as error:
            availability_errors.append(str(error))
            continue
        if isinstance(candidate, list):
            if len(candidate) == 1:
                availability = candidate[0]
                break
            if len(candidate) > 1:
                raise RuntimeError(
                    f"App {app_id} has multiple AppAvailability resources"
                )
        elif candidate:
            availability = candidate
            break
    if not availability:
        attempted = "\n".join(availability_errors)
        raise RuntimeError(
            f"App {app_id} has no readable AppAvailability resource.\n{attempted}"
        )
    availability_id = str(availability["id"])
    availability_type = str(availability.get("type") or "appAvailabilities")
    rows = None
    relationship_errors: list[str] = []
    relationship_paths = (
        f"/v2/appAvailabilities/{availability_id}/territoryAvailabilities"
        "?limit=200&include=territory"
        "&fields[territoryAvailabilities]=available,contentStatuses,territory",
        f"/v1/{availability_type}/{availability_id}/territoryAvailabilities"
        "?include=territory&limit=200",
    )
    for relationship_path in relationship_paths:
        try:
            rows = api.list_all(relationship_path)
            break
        except RuntimeError as error:
            relationship_errors.append(str(error))
    if rows is None:
        attempted = "\n".join(relationship_errors)
        raise RuntimeError(
            "Could not read territoryAvailabilities relationship.\n" + attempted
        )
    territories: list[TerritoryState] = []
    for row in rows:
        relationship = (
            row.get("relationships", {}).get("territory", {}).get("data") or {}
        )
        territory_id = str(relationship.get("id") or "")
        if not territory_id:
            raise RuntimeError(
                f"TerritoryAvailability {row.get('id')} has no territory relationship"
            )
        territories.append(
            TerritoryState(
                resource_id=str(row["id"]),
                territory_id=territory_id,
                available=bool(row.get("attributes", {}).get("available")),
            )
        )
    if not territories:
        raise RuntimeError("App availability returned no territories")
    return availability, territories


def print_audit(availability: dict[str, Any], territories: list[TerritoryState]) -> None:
    china = next((row for row in territories if row.territory_id == CHINA_TERRITORY), None)
    available_count = sum(row.available for row in territories)
    print(
        "App availability: "
        f"availableInNewTerritories="
        f"{availability.get('attributes', {}).get('availableInNewTerritories')} "
        f"availableTerritories={available_count}/{len(territories)}"
    )
    print(
        f"Mainland China ({CHINA_TERRITORY}) available="
        f"{bool(china and china.available)}"
    )


def exclude_china(api: AppStoreConnect, app_id: str, confirmation: str) -> None:
    if confirmation != MUTATION_CONFIRMATION:
        raise RuntimeError(
            "Refusing to mutate availability without exact confirmation "
            f"{MUTATION_CONFIRMATION}"
        )
    availability, territories = load_availability(api, app_id)
    print_audit(availability, territories)
    china = next(
        (row for row in territories if row.territory_id == CHINA_TERRITORY), None
    )

    if china and china.available:
        api.request(
            "PATCH",
            f"/v1/territoryAvailabilities/{china.resource_id}",
            payload=territory_availability_patch(china.resource_id),
        )
        print("Excluded Mainland China from app availability.")
    else:
        print("Mainland China is already excluded.")

    verified_availability, verified_territories = load_availability(api, app_id)
    print_audit(verified_availability, verified_territories)
    verified_china = next(
        (
            row
            for row in verified_territories
            if row.territory_id == CHINA_TERRITORY
        ),
        None,
    )
    if verified_china and verified_china.available:
        raise RuntimeError("Mainland China is still available after the update")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=("audit", "exclude-china"), default="audit")
    parser.add_argument("--bundle-id", default=BUNDLE_ID)
    parser.add_argument("--confirmation", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    api = AppStoreConnect()
    app_id = find_app_id(api, args.bundle_id)
    if args.action == "exclude-china":
        exclude_china(api, app_id, args.confirmation)
        return
    availability, territories = load_availability(api, app_id)
    print_audit(availability, territories)


if __name__ == "__main__":
    main()
