#!/usr/bin/env python3
"""Replay one narrowly matched Apple notification through the verified webhook.

The App Store Server API response is authenticated with an Apple In-App
Purchase key. The notification itself is still treated as untrusted here: the
Supabase webhook performs the authoritative Apple JWS verification before any
profile or ledger mutation.
"""

from __future__ import annotations

import base64
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Iterable


PRODUCTION_API = "https://api.storekit.apple.com"
HISTORY_PATH = "/inApps/v1/notifications/history"
EXPECTED_BUNDLE_ID = "com.x5studio.app"
EXPECTED_APP_ACCOUNT_TOKEN = "f4e32ce0-ca32-45ad-a63e-cc3b4a526881"
EXPECTED_PRODUCT_ID = "com.x5studio.app.lite.monthly"
EXPECTED_NOTIFICATION_TYPE = "SUBSCRIBED"
EXPECTED_SUBTYPE = "INITIAL_BUY"
EXPECTED_PURCHASE_START_MS = 1784553600000  # 2026-07-20 13:20:00 UTC
EXPECTED_PURCHASE_END_MS = 1784554200000  # 2026-07-20 13:30:00 UTC
EXPECTED_HISTORY_START_MS = 1784553300000  # 2026-07-20 13:15:00 UTC
EXPECTED_HISTORY_END_MS = 1784556900000  # 2026-07-20 14:15:00 UTC
MAX_HISTORY_WINDOW_MS = 60 * 60 * 1000
MAX_PAGES = 20


def _decode_base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def decode_jws_payload(value: str) -> dict[str, Any]:
    """Decode a JWS payload for routing only; do not treat it as verified."""

    parts = value.split(".")
    if len(parts) != 3 or not parts[1]:
        raise ValueError("invalid_jws")
    payload = json.loads(_decode_base64url(parts[1]))
    if not isinstance(payload, dict):
        raise ValueError("invalid_jws_payload")
    return payload


@dataclass(frozen=True)
class MatchedNotification:
    signed_payload: str
    notification_type: str
    subtype: str | None
    product_id: str
    environment: str
    transaction_id: str
    original_transaction_id: str
    purchase_date: int


def match_notification(
    signed_payload: str,
    *,
    target_user_id: str,
    bundle_id: str,
) -> MatchedNotification | None:
    """Return only the exact production Lite notification for this X5 user."""

    try:
        outer = decode_jws_payload(signed_payload)
        data = outer.get("data")
        if not isinstance(data, dict):
            return None
        signed_transaction = data.get("signedTransactionInfo")
        if not isinstance(signed_transaction, str):
            return None
        transaction = decode_jws_payload(signed_transaction)
    except (ValueError, TypeError, json.JSONDecodeError):
        return None

    notification_type = outer.get("notificationType")
    subtype = outer.get("subtype")
    environment = data.get("environment")
    if notification_type != EXPECTED_NOTIFICATION_TYPE:
        return None
    if subtype != EXPECTED_SUBTYPE:
        return None
    if data.get("bundleId") != bundle_id:
        return None
    if environment != "Production":
        return None
    if transaction.get("environment") != "Production":
        return None
    if transaction.get("bundleId") != bundle_id:
        return None
    if transaction.get("productId") != EXPECTED_PRODUCT_ID:
        return None
    if str(transaction.get("appAccountToken", "")).lower() != target_user_id.lower():
        return None
    if transaction.get("type") != "Auto-Renewable Subscription":
        return None
    if transaction.get("inAppOwnershipType") != "PURCHASED":
        return None
    if transaction.get("quantity") != 1:
        return None

    transaction_id = transaction.get("transactionId")
    original_transaction_id = transaction.get("originalTransactionId")
    purchase_date = transaction.get("purchaseDate")
    if not isinstance(transaction_id, str) or not transaction_id:
        return None
    if not isinstance(original_transaction_id, str) or not original_transaction_id:
        return None
    # An INITIAL_BUY is the first transaction in this subscription chain.
    if transaction_id != original_transaction_id:
        return None
    if not isinstance(purchase_date, int):
        return None
    if not EXPECTED_PURCHASE_START_MS <= purchase_date <= EXPECTED_PURCHASE_END_MS:
        return None

    return MatchedNotification(
        signed_payload=signed_payload,
        notification_type=str(notification_type),
        subtype=str(subtype) if subtype is not None else None,
        product_id=EXPECTED_PRODUCT_ID,
        environment="Production",
        transaction_id=transaction_id,
        original_transaction_id=original_transaction_id,
        purchase_date=purchase_date,
    )


def matching_notifications(
    items: Iterable[dict[str, Any]],
    *,
    target_user_id: str,
    bundle_id: str,
) -> list[MatchedNotification]:
    matches: list[MatchedNotification] = []
    for item in items:
        signed_payload = item.get("signedPayload")
        if not isinstance(signed_payload, str):
            continue
        match = match_notification(
            signed_payload,
            target_user_id=target_user_id,
            bundle_id=bundle_id,
        )
        if match is not None:
            matches.append(match)
    return matches


def safe_notification_summary(
    signed_payload: str,
    *,
    target_user_id: str,
    bundle_id: str,
) -> str:
    """Return non-secret routing facts for a notification that did not match."""

    try:
        outer = decode_jws_payload(signed_payload)
        data = outer.get("data")
        if not isinstance(data, dict):
            return (
                f"type={outer.get('notificationType') or '-'} "
                f"subtype={outer.get('subtype') or '-'} data=missing"
            )
        signed_transaction = data.get("signedTransactionInfo")
        if not isinstance(signed_transaction, str):
            return (
                f"type={outer.get('notificationType') or '-'} "
                f"subtype={outer.get('subtype') or '-'} "
                f"bundle_match={data.get('bundleId') == bundle_id} "
                f"environment={data.get('environment') or '-'} transaction=missing"
            )
        transaction = decode_jws_payload(signed_transaction)
    except (ValueError, TypeError, json.JSONDecodeError):
        return "decode=failed"

    purchase_date = transaction.get("purchaseDate")
    purchase_in_window = (
        isinstance(purchase_date, int)
        and EXPECTED_PURCHASE_START_MS <= purchase_date <= EXPECTED_PURCHASE_END_MS
    )
    transaction_id = transaction.get("transactionId")
    original_transaction_id = transaction.get("originalTransactionId")
    initial_transaction = (
        isinstance(transaction_id, str)
        and bool(transaction_id)
        and transaction_id == original_transaction_id
    )
    return (
        f"type={outer.get('notificationType') or '-'} "
        f"subtype={outer.get('subtype') or '-'} "
        f"bundle_match={data.get('bundleId') == bundle_id} "
        f"environment={data.get('environment') or '-'} "
        f"product={transaction.get('productId') or '-'} "
        f"account_match={str(transaction.get('appAccountToken', '')).lower() == target_user_id.lower()} "
        f"purchase_in_window={purchase_in_window} "
        f"initial_transaction={initial_transaction} "
        f"ownership={transaction.get('inAppOwnershipType') or '-'} "
        f"quantity={transaction.get('quantity') if transaction.get('quantity') is not None else '-'}"
    )


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing_{name.lower()}")
    return value


def _apple_token() -> str:
    import jwt

    now = int(time.time())
    return jwt.encode(
        {
            "iss": _required("IAP_API_ISSUER_ID"),
            "iat": now,
            "exp": now + 5 * 60,
            "aud": "appstoreconnect-v1",
            "bid": _required("BUNDLE_ID"),
        },
        base64.b64decode(_required("IAP_API_KEY_BASE64")),
        algorithm="ES256",
        headers={"kid": _required("IAP_API_KEY_ID"), "typ": "JWT"},
    )


def fetch_history(start_ms: int, end_ms: int) -> list[dict[str, Any]]:
    import requests

    if start_ms >= end_ms:
        raise RuntimeError("invalid_history_window")
    if end_ms - start_ms > MAX_HISTORY_WINDOW_MS:
        raise RuntimeError("history_window_too_wide")

    items: list[dict[str, Any]] = []
    pagination_token: str | None = None
    for _ in range(MAX_PAGES):
        params = {"paginationToken": pagination_token} if pagination_token else None
        response = requests.post(
            f"{PRODUCTION_API}{HISTORY_PATH}",
            params=params,
            headers={
                "Authorization": f"Bearer {_apple_token()}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            json={"startDate": start_ms, "endDate": end_ms},
            timeout=60,
        )
        if response.status_code != 200:
            try:
                error = response.json()
                code = error.get("errorCode")
                message = str(error.get("errorMessage", ""))[:240]
            except (ValueError, AttributeError):
                code, message = None, ""
            raise RuntimeError(
                f"apple_history_http_{response.status_code}:code={code}:message={message}"
            )

        payload = response.json()
        page_items = payload.get("notificationHistory", [])
        if not isinstance(page_items, list):
            raise RuntimeError("invalid_apple_history_response")
        items.extend(item for item in page_items if isinstance(item, dict))
        if not payload.get("hasMore"):
            return items
        pagination_token = payload.get("paginationToken")
        if not isinstance(pagination_token, str) or not pagination_token:
            raise RuntimeError("missing_pagination_token")

    raise RuntimeError("apple_history_page_limit")


def replay(match: MatchedNotification) -> tuple[int, str]:
    import requests

    response = requests.post(
        _required("APP_STORE_NOTIFICATIONS_URL"),
        headers={"Content-Type": "application/json"},
        json={"signedPayload": match.signed_payload},
        timeout=60,
    )
    try:
        payload = response.json()
        safe_result = str(payload.get("status") or payload.get("error") or "")[:120]
    except (ValueError, AttributeError):
        safe_result = ""
    return response.status_code, safe_result


def select_single_notification(
    matches: list[MatchedNotification],
) -> MatchedNotification:
    """Fail closed unless history contains exactly one exact Apple purchase."""

    if len(matches) != 1:
        raise RuntimeError(f"expected_one_exact_match_found_{len(matches)}")
    match = matches[0]
    if match.transaction_id != match.original_transaction_id:
        raise RuntimeError("unexpected_subscription_chain")
    return match


def delivery_applied(status: int, result: str) -> bool:
    return status == 200 and result in {"applied", "already_applied"}


def main() -> None:
    target_user_id = _required("TARGET_APP_ACCOUNT_TOKEN").lower()
    bundle_id = _required("BUNDLE_ID")
    start_ms = int(_required("HISTORY_START_MS"))
    end_ms = int(_required("HISTORY_END_MS"))

    if target_user_id != EXPECTED_APP_ACCOUNT_TOKEN:
        raise SystemExit("Recovery target is not the approved X5 account")
    if bundle_id != EXPECTED_BUNDLE_ID:
        raise SystemExit("Recovery bundle is not the approved X5 app")
    if (start_ms, end_ms) != (EXPECTED_HISTORY_START_MS, EXPECTED_HISTORY_END_MS):
        raise SystemExit("Recovery history window is not the approved outage window")

    history = fetch_history(start_ms, end_ms)
    matches = matching_notifications(
        history,
        target_user_id=target_user_id,
        bundle_id=bundle_id,
    )
    print(f"history_records={len(history)} exact_matches={len(matches)}")
    if len(matches) != 1:
        for index, item in enumerate(history, start=1):
            signed_payload = item.get("signedPayload")
            if isinstance(signed_payload, str):
                print(
                    f"history_record={index} "
                    + safe_notification_summary(
                        signed_payload,
                        target_user_id=target_user_id,
                        bundle_id=bundle_id,
                    )
                )
    try:
        match = select_single_notification(matches)
    except RuntimeError as error:
        raise SystemExit(str(error)) from error

    status, result = replay(match)
    print(
        "replay "
        f"type={match.notification_type} subtype={match.subtype or '-'} "
        f"product={match.product_id} environment={match.environment} "
        f"http={status} result={result or '-'}"
    )
    if not delivery_applied(status, result):
        raise SystemExit("Apple notification replay did not apply the entitlement")


if __name__ == "__main__":
    main()
