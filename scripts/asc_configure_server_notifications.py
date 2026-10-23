#!/usr/bin/env python3
"""Configure App Store Server Notifications V2 for X Five."""

from __future__ import annotations

import base64
import os
import time
from typing import Any
from urllib.parse import urlsplit, urlunsplit


API_ROOT = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.x5studio.app"
DEFAULT_ENDPOINT = (
    "https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/"
    "app-store-notifications"
)


def normalize_endpoint(value: str) -> str:
    endpoint = value.strip().rstrip("/")
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path in ("", "/")
    ):
        raise ValueError("Notification endpoint must be a credential-free HTTPS URL")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def notification_attributes(endpoint: str) -> dict[str, str]:
    return {
        "subscriptionStatusUrl": endpoint,
        "subscriptionStatusUrlForSandbox": endpoint,
        "subscriptionStatusUrlVersion": "V2",
        "subscriptionStatusUrlVersionForSandbox": "V2",
    }


def build_app_update_payload(app_id: str, endpoint: str) -> dict[str, Any]:
    normalized = normalize_endpoint(endpoint)
    return {
        "data": {
            "type": "apps",
            "id": app_id,
            "attributes": notification_attributes(normalized),
        }
    }


def readback_matches(attributes: dict[str, Any], endpoint: str) -> bool:
    desired = notification_attributes(normalize_endpoint(endpoint))
    return all(attributes.get(key) == value for key, value in desired.items())


class AppStoreConnect:
    def __init__(self) -> None:
        import jwt
        import requests

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
        self.requests = requests
        self.headers = {"Authorization": f"Bearer {token}"}

    def request(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        response = self.requests.request(
            method,
            f"{API_ROOT}{path}",
            headers={
                **self.headers,
                **({"Content-Type": "application/json"} if payload else {}),
            },
            json=payload,
            timeout=60,
        )
        if response.status_code not in (200,):
            raise RuntimeError(
                f"{method} {path} -> HTTP {response.status_code}: "
                f"{response.text[:2000]}"
            )
        return response.json()


def configure() -> None:
    endpoint = normalize_endpoint(
        os.environ.get("APP_STORE_NOTIFICATIONS_URL", DEFAULT_ENDPOINT)
    )
    api = AppStoreConnect()
    fields = ",".join(notification_attributes(endpoint))
    lookup_path = (
        f"/v1/apps?filter[bundleId]={BUNDLE_ID}"
        f"&fields[apps]=bundleId,{fields}&limit=2"
    )
    apps = api.request("GET", lookup_path).get("data", [])
    if len(apps) != 1:
        raise RuntimeError(
            f"Expected exactly one App Store Connect app for {BUNDLE_ID}; "
            f"found {len(apps)}"
        )

    app = apps[0]
    app_id = app["id"]
    if not readback_matches(app.get("attributes", {}), endpoint):
        api.request(
            "PATCH",
            f"/v1/apps/{app_id}",
            payload=build_app_update_payload(app_id, endpoint),
        )

    verified = api.request(
        "GET", f"/v1/apps/{app_id}?fields[apps]=bundleId,{fields}"
    )
    attributes = verified.get("data", {}).get("attributes", {})
    if not readback_matches(attributes, endpoint):
        raise RuntimeError("App Store Connect notification URL readback mismatch")

    print(f"Configured App Store Server Notifications V2: {endpoint}")
    print("Verified identical Production and Sandbox URLs by API readback")


if __name__ == "__main__":
    configure()
