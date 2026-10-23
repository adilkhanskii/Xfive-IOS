#!/usr/bin/env python3
"""Read-only audit of narrowly approved Apple Sandbox notification windows.

This program only calls Apple's Notification History endpoint. It never sends a
signed payload to the X5 backend, never calls a delivery endpoint, and never
changes an entitlement or credit balance. Console and artifact output omit JWS
payloads, app-account tokens, and complete Apple transaction identifiers.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable


SANDBOX_HISTORY_URL = (
    "https://api.storekit-sandbox.apple.com/inApps/v1/notifications/history"
)
BUNDLE_ID = "com.x5studio.app"
MAX_HISTORY_WINDOW_MS = 60 * 60 * 1000
MAX_PAGES = 20
MAX_SAFE_OBSERVED = 50


@dataclass(frozen=True)
class AuditWindow:
    label: str
    app_account_token: str
    product_ids: tuple[str, ...]
    notification_type: str
    subtype: str | None
    transaction_type: str
    start_ms: int
    end_ms: int


# These immutable windows cover only the customer-reported incidents. Widening
# them requires an explicit code review rather than a workflow input.
AUDIT_WINDOWS = (
    AuditWindow(
        label="adilkhan_credits_2000",
        app_account_token="eee55a08-18d1-46e3-a303-1411d1bb9333",
        product_ids=("com.x5studio.app.credits.2000",),
        notification_type="ONE_TIME_CHARGE",
        subtype=None,
        transaction_type="Consumable",
        start_ms=1784533500000,  # 2026-07-20 07:45:00 UTC
        end_ms=1784535000000,  # 2026-07-20 08:10:00 UTC
    ),
    AuditWindow(
        label="dossymkhan_lite",
        app_account_token="f4e32ce0-ca32-45ad-a63e-cc3b4a526881",
        product_ids=("com.x5studio.app.lite.monthly",),
        notification_type="SUBSCRIBED",
        subtype="INITIAL_BUY",
        transaction_type="Auto-Renewable Subscription",
        start_ms=1784553300000,  # 2026-07-20 13:15:00 UTC
        end_ms=1784556900000,  # 2026-07-20 14:15:00 UTC
    ),
)
APPROVED_WINDOWS = frozenset((item.start_ms, item.end_ms) for item in AUDIT_WINDOWS)


def _decode_base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _decode_jws_payload(value: str) -> dict[str, Any]:
    parts = value.split(".")
    if len(parts) != 3 or not parts[1]:
        raise ValueError("invalid_jws")
    payload = json.loads(_decode_base64url(parts[1]))
    if not isinstance(payload, dict):
        raise ValueError("invalid_jws_payload")
    return payload


def _safe_text(value: Any, limit: int = 120) -> str:
    if not isinstance(value, str) or not value:
        return "-"
    return value[:limit]


def _fingerprint(value: Any) -> str:
    if not isinstance(value, str) or not value:
        return "-"
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def safe_notification_summary(
    signed_payload: str,
    window: AuditWindow,
) -> dict[str, Any]:
    """Decode only for routing and return a non-sensitive audit summary."""

    try:
        outer = _decode_jws_payload(signed_payload)
        data = outer.get("data")
        if not isinstance(data, dict):
            raise ValueError("missing_data")
        signed_transaction = data.get("signedTransactionInfo")
        if not isinstance(signed_transaction, str):
            raise ValueError("missing_transaction")
        transaction = _decode_jws_payload(signed_transaction)
    except (ValueError, TypeError, json.JSONDecodeError):
        return {"exact_match": False, "decode": "failed"}

    notification_type = outer.get("notificationType")
    subtype = outer.get("subtype")
    environment = data.get("environment")
    transaction_environment = transaction.get("environment")
    product_id = transaction.get("productId")
    purchase_date = transaction.get("purchaseDate")
    transaction_id = transaction.get("transactionId")
    original_transaction_id = transaction.get("originalTransactionId")
    account_match = (
        str(transaction.get("appAccountToken", "")).lower()
        == window.app_account_token.lower()
    )
    purchase_in_window = (
        isinstance(purchase_date, int)
        and window.start_ms <= purchase_date <= window.end_ms
    )
    initial_transaction = (
        isinstance(transaction_id, str)
        and bool(transaction_id)
        and transaction_id == original_transaction_id
    )
    subtype_match = subtype == window.subtype

    exact_match = all(
        (
            notification_type == window.notification_type,
            subtype_match,
            data.get("bundleId") == BUNDLE_ID,
            transaction.get("bundleId") == BUNDLE_ID,
            environment == "Sandbox",
            transaction_environment == "Sandbox",
            product_id in window.product_ids,
            account_match,
            transaction.get("type") == window.transaction_type,
            transaction.get("inAppOwnershipType") == "PURCHASED",
            transaction.get("quantity") == 1,
            purchase_in_window,
            initial_transaction,
        )
    )

    return {
        "exact_match": exact_match,
        "notification_type": _safe_text(notification_type),
        "subtype": _safe_text(subtype),
        "environment": _safe_text(environment),
        "product_id": _safe_text(product_id),
        "account_match": account_match,
        "purchase_in_window": purchase_in_window,
        "purchase_date_ms": purchase_date if isinstance(purchase_date, int) else None,
        "initial_transaction": initial_transaction,
        "ownership": _safe_text(transaction.get("inAppOwnershipType")),
        "quantity": (
            transaction.get("quantity")
            if isinstance(transaction.get("quantity"), int)
            else None
        ),
        "transaction_fingerprint": _fingerprint(transaction_id),
    }


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
            "bid": BUNDLE_ID,
        },
        base64.b64decode(_required("IAP_API_KEY_BASE64")),
        algorithm="ES256",
        headers={"kid": _required("IAP_API_KEY_ID"), "typ": "JWT"},
    )


def fetch_history(
    start_ms: int,
    end_ms: int,
    *,
    post: Callable[..., Any] | None = None,
    token_factory: Callable[[], str] | None = None,
) -> list[dict[str, Any]]:
    """Read one approved window from Apple's Sandbox history API."""

    if (start_ms, end_ms) not in APPROVED_WINDOWS:
        raise RuntimeError("history_window_not_approved")
    if start_ms >= end_ms or end_ms - start_ms > MAX_HISTORY_WINDOW_MS:
        raise RuntimeError("invalid_history_window")

    if post is None:
        import requests

        post = requests.post
    if token_factory is None:
        token_factory = _apple_token

    items: list[dict[str, Any]] = []
    pagination_token: str | None = None
    for _ in range(MAX_PAGES):
        params = {"paginationToken": pagination_token} if pagination_token else None
        response = post(
            SANDBOX_HISTORY_URL,
            params=params,
            headers={
                "Authorization": f"Bearer {token_factory()}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            json={"startDate": start_ms, "endDate": end_ms},
            timeout=60,
        )
        if response.status_code != 200:
            try:
                error_code = response.json().get("errorCode")
            except (ValueError, AttributeError):
                error_code = None
            raise RuntimeError(
                f"apple_sandbox_history_http_{response.status_code}:"
                f"code={error_code or '-'}"
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


def audit_sandbox_history(
    *,
    fetcher: Callable[[int, int], list[dict[str, Any]]] = fetch_history,
    now_ms: int | None = None,
    windows: Iterable[AuditWindow] = AUDIT_WINDOWS,
) -> dict[str, Any]:
    """Build a safe report without retaining signed payloads or complete IDs."""

    report_windows: list[dict[str, Any]] = []
    for window in windows:
        history = fetcher(window.start_ms, window.end_ms)
        observed: list[dict[str, Any]] = []
        exact_matches: list[dict[str, Any]] = []
        decoded_records = 0
        for item in history:
            signed_payload = item.get("signedPayload")
            if not isinstance(signed_payload, str):
                continue
            summary = safe_notification_summary(signed_payload, window)
            if summary.get("decode") != "failed":
                decoded_records += 1
            if len(observed) < MAX_SAFE_OBSERVED:
                observed.append(summary)
            if summary.get("exact_match"):
                exact_matches.append(summary)

        report_windows.append(
            {
                "target": window.label,
                "start_ms": window.start_ms,
                "end_ms": window.end_ms,
                "history_records": len(history),
                "decoded_records": decoded_records,
                "exact_matches": len(exact_matches),
                "observed_records": observed,
                "observed_truncated": max(0, len(history) - len(observed)),
            }
        )

    return {
        "schema_version": 1,
        "mode": "read_only_notification_history",
        "environment": "Sandbox",
        "bundle_id": BUNDLE_ID,
        "generated_at_ms": int(time.time() * 1000) if now_ms is None else now_ms,
        "windows": report_windows,
    }


def _write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Read-only audit of approved Apple Sandbox history windows"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("apple-sandbox-history-audit.json"),
    )
    args = parser.parse_args()

    report = audit_sandbox_history()
    _write_report(args.output, report)
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
