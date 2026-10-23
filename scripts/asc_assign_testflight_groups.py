"""Guarded App Store Connect assignment of build 243 to internal beta groups."""

from __future__ import annotations

import argparse
import base64
import os
import time
from typing import Iterable, Protocol


EXPECTED_BUILD = "251"
EXPECTED_GROUP_NAMES = frozenset({"123", "321"})


class TestFlightClient(Protocol):
    def find_app_id(self, bundle_id: str) -> str: ...

    def list_builds(self, app_id: str) -> list[dict]: ...

    def list_beta_groups(self, app_id: str) -> list[dict]: ...

    def list_group_build_ids(self, group_id: str) -> set[str]: ...

    def add_build_to_group(self, group_id: str, build_id: str) -> None: ...


def assign_internal_groups(
    client: TestFlightClient,
    *,
    bundle_id: str,
    build_number: str,
    group_names: Iterable[str],
) -> dict[str, str]:
    """Assign exactly X5 build 243 to the two existing approved internal groups."""

    requested_names = tuple(group_names)
    if bundle_id != "com.x5studio.app":
        raise ValueError("Refusing a non-X5 bundle")
    if build_number != EXPECTED_BUILD:
        raise ValueError(
            f"Refusing build {build_number}; this operation is locked to {EXPECTED_BUILD}"
        )
    if len(requested_names) != len(EXPECTED_GROUP_NAMES) or set(
        requested_names
    ) != EXPECTED_GROUP_NAMES:
        raise ValueError(
            "Refusing unexpected groups; allowed groups are exactly 123 and 321"
        )

    app_id = client.find_app_id(bundle_id)
    matching_builds = [
        row
        for row in client.list_builds(app_id)
        if row.get("attributes", {}).get("version") == build_number
    ]
    if len(matching_builds) != 1:
        raise ValueError(
            f"Expected exactly one build {build_number}, found {len(matching_builds)}"
        )
    build = matching_builds[0]
    build_attrs = build.get("attributes", {})
    if build_attrs.get("processingState") != "VALID" or build_attrs.get("expired"):
        raise ValueError(
            f"Build {build_number} is not safely assignable: {build_attrs}"
        )

    groups_by_name: dict[str, dict] = {}
    for group in client.list_beta_groups(app_id):
        name = group.get("attributes", {}).get("name")
        if name in EXPECTED_GROUP_NAMES:
            if name in groups_by_name:
                raise ValueError(f"More than one beta group is named {name}")
            groups_by_name[name] = group

    missing = EXPECTED_GROUP_NAMES - groups_by_name.keys()
    if missing:
        raise ValueError(f"Missing beta groups: {sorted(missing)}")

    # Validate every target before the first mutation so the operation is all-safe.
    for name in requested_names:
        attrs = groups_by_name[name].get("attributes", {})
        if attrs.get("isInternalGroup") is not True:
            raise ValueError(f"Refusing non-internal beta group {name}")
        if attrs.get("publicLinkEnabled") is True:
            raise ValueError(f"Refusing public-link beta group {name}")

    build_id = build["id"]
    result: dict[str, str] = {}
    for name in requested_names:
        group_id = groups_by_name[name]["id"]
        current = client.list_group_build_ids(group_id)
        if build_id not in current:
            client.add_build_to_group(group_id, build_id)

        # Fresh GET after each relationship mutation is mandatory.
        confirmed = client.list_group_build_ids(group_id)
        if build_id not in confirmed:
            raise RuntimeError(
                f"App Store Connect did not confirm build {build_number} in group {name}"
            )
        result[name] = "confirmed"

    return result


class AppStoreConnectClient:
    BASE_URL = "https://api.appstoreconnect.apple.com/v1"

    def __init__(self, token: str):
        import requests

        self._requests = requests
        self._headers = {"Authorization": f"Bearer {token}"}

    @classmethod
    def from_env(cls) -> "AppStoreConnectClient":
        import jwt

        token = jwt.encode(
            {
                "iss": os.environ["ASC_API_ISSUER_ID"],
                "iat": int(time.time()),
                "exp": int(time.time()) + 600,
                "aud": "appstoreconnect-v1",
            },
            base64.b64decode(os.environ["ASC_API_KEY_BASE64"]),
            algorithm="ES256",
            headers={"kid": os.environ["ASC_API_KEY_ID"], "typ": "JWT"},
        )
        return cls(token)

    def _get_all(self, path: str, params: dict | None = None) -> list[dict]:
        rows: list[dict] = []
        url = f"{self.BASE_URL}{path}"
        next_params = params
        while url:
            response = self._requests.get(
                url,
                headers=self._headers,
                params=next_params,
                timeout=60,
            )
            response.raise_for_status()
            payload = response.json()
            rows.extend(payload.get("data", []))
            url = payload.get("links", {}).get("next")
            next_params = None
        return rows

    def find_app_id(self, bundle_id: str) -> str:
        apps = self._get_all("/apps", {"filter[bundleId]": bundle_id})
        if len(apps) != 1:
            raise ValueError(f"Expected one app for {bundle_id}, found {len(apps)}")
        return apps[0]["id"]

    def list_builds(self, app_id: str) -> list[dict]:
        return self._get_all(
            "/builds",
            {
                "filter[app]": app_id,
                "filter[preReleaseVersion.platform]": "IOS",
                "limit": 200,
                "sort": "-uploadedDate",
            },
        )

    def list_beta_groups(self, app_id: str) -> list[dict]:
        return self._get_all(f"/apps/{app_id}/betaGroups", {"limit": 200})

    def list_group_build_ids(self, group_id: str) -> set[str]:
        rows = self._get_all(f"/betaGroups/{group_id}/builds", {"limit": 200})
        return {row["id"] for row in rows}

    def add_build_to_group(self, group_id: str, build_id: str) -> None:
        response = self._requests.post(
            f"{self.BASE_URL}/betaGroups/{group_id}/relationships/builds",
            headers={**self._headers, "Content-Type": "application/json"},
            json={"data": [{"type": "builds", "id": build_id}]},
            timeout=60,
        )
        if response.status_code not in {200, 201, 204}:
            raise RuntimeError(
                f"Failed to assign build to group {group_id}: "
                f"HTTP {response.status_code} {response.text[:1000]}"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", required=True)
    parser.add_argument("--group", action="append", required=True)
    parser.add_argument("--bundle-id", default="com.x5studio.app")
    args = parser.parse_args()

    result = assign_internal_groups(
        AppStoreConnectClient.from_env(),
        bundle_id=args.bundle_id,
        build_number=args.build,
        group_names=args.group,
    )
    for name in args.group:
        print(f"ASSIGN_CONFIRMED build={args.build} group={name} status={result[name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
