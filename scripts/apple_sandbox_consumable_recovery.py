#!/usr/bin/env python3
"""Recover one exact Apple Sandbox consumable through the verified X5 webhook.

The only mutable action in this program is replaying Apple's original signed
notification payload to the fixed X5 App Store Server Notifications endpoint.
Apple history is authenticated, the candidates are matched against immutable
incident windows, and the webhook remains the authority that verifies every
Apple JWS before applying an exact-once ledger entry.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any, Callable, Iterable

from scripts.apple_sandbox_history_audit import (
    AUDIT_WINDOWS,
    BUNDLE_ID,
    AuditWindow,
    fetch_history,
)


FIXED_WEBHOOK_URL = (
    "https://afwznqjpshybmqhlewmy.supabase.co/"
    "functions/v1/app-store-notifications"
)

# Match the audited incident windows exactly. Keeping this second immutable
# contract makes any later widening of the read-only auditor fail closed here.
_EXPECTED_TARGET_CONTRACT = (
    (
        "adilkhan_credits_2000",
        "eee55a08-18d1-46e3-a303-1411d1bb9333",
        ("com.x5studio.app.credits.2000",),
        "ONE_TIME_CHARGE",
        None,
        "Consumable",
        1784533500000,
        1784535000000,
    ),
)


def _target_contract(window: AuditWindow) -> tuple[Any, ...]:
    return (
        window.label,
        window.app_account_token,
        window.product_ids,
        window.notification_type,
        window.subtype,
        window.transaction_type,
        window.start_ms,
        window.end_ms,
    )


def _load_recovery_targets() -> tuple[AuditWindow, ...]:
    by_label = {window.label: window for window in AUDIT_WINDOWS}
    labels = tuple(contract[0] for contract in _EXPECTED_TARGET_CONTRACT)
    try:
        targets = tuple(by_label[label] for label in labels)
    except KeyError as error:
        raise RuntimeError("approved_recovery_target_missing") from error
    if tuple(_target_contract(target) for target in targets) != _EXPECTED_TARGET_CONTRACT:
        raise RuntimeError("approved_recovery_target_contract_changed")
    return targets


RECOVERY_TARGETS = _load_recovery_targets()


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


def normalize_quantity(transaction: dict[str, Any]) -> int:
    """Normalize Apple's omitted/null consumable quantity to one, fail closed otherwise."""

    value = transaction.get("quantity")
    if value is None:
        return 1
    if type(value) is int and value == 1:
        return 1
    raise ValueError("unsupported_quantity")


@dataclass(frozen=True)
class RecoveryMatch:
    signed_payload: str
    transaction_id: str
    quantity: int


@dataclass(frozen=True)
class RecoveryPlanItem:
    target: AuditWindow
    match: RecoveryMatch


def match_notification(
    signed_payload: str,
    target: AuditWindow,
) -> RecoveryMatch | None:
    """Decode for routing and return only the exact approved Sandbox purchase."""

    if target not in RECOVERY_TARGETS:
        raise RuntimeError("recovery_target_not_approved")
    try:
        outer = _decode_jws_payload(signed_payload)
        data = outer.get("data")
        if not isinstance(data, dict):
            return None
        signed_transaction = data.get("signedTransactionInfo")
        if not isinstance(signed_transaction, str):
            return None
        transaction = _decode_jws_payload(signed_transaction)
        quantity = normalize_quantity(transaction)
    except (ValueError, TypeError, json.JSONDecodeError):
        return None

    transaction_id = transaction.get("transactionId")
    original_transaction_id = transaction.get("originalTransactionId")
    purchase_date = transaction.get("purchaseDate")
    exact = all(
        (
            outer.get("notificationType") == target.notification_type,
            outer.get("subtype") == target.subtype,
            data.get("bundleId") == BUNDLE_ID,
            data.get("environment") == "Sandbox",
            transaction.get("bundleId") == BUNDLE_ID,
            transaction.get("environment") == "Sandbox",
            transaction.get("productId") in target.product_ids,
            str(transaction.get("appAccountToken", "")).lower()
            == target.app_account_token.lower(),
            transaction.get("type") == target.transaction_type,
            transaction.get("inAppOwnershipType") == "PURCHASED",
            type(purchase_date) is int,
            type(purchase_date) is int
            and target.start_ms <= purchase_date <= target.end_ms,
            isinstance(transaction_id, str),
            bool(transaction_id),
            transaction_id == original_transaction_id,
        )
    )
    if not exact:
        return None
    return RecoveryMatch(
        signed_payload=signed_payload,
        transaction_id=transaction_id,
        quantity=quantity,
    )


def select_one_unique_match(
    history: Iterable[dict[str, Any]],
    target: AuditWindow,
) -> RecoveryMatch:
    """Fail closed unless one unique original signed payload matches the target."""

    unique: dict[str, RecoveryMatch] = {}
    for item in history:
        signed_payload = item.get("signedPayload")
        if not isinstance(signed_payload, str):
            continue
        match = match_notification(signed_payload, target)
        if match is not None:
            unique.setdefault(signed_payload, match)
    if len(unique) != 1:
        raise RuntimeError(
            f"target={target.label}:expected_one_unique_match_found_{len(unique)}"
        )
    return next(iter(unique.values()))


def build_recovery_plan(
    *,
    fetcher: Callable[[int, int], list[dict[str, Any]]] = fetch_history,
) -> list[RecoveryPlanItem]:
    """Resolve both approved targets before allowing either delivery."""

    plan: list[RecoveryPlanItem] = []
    for target in RECOVERY_TARGETS:
        history = fetcher(target.start_ms, target.end_ms)
        plan.append(
            RecoveryPlanItem(
                target=target,
                match=select_one_unique_match(history, target),
            )
        )
    if len(plan) != len(RECOVERY_TARGETS):
        raise RuntimeError("incomplete_recovery_plan")
    return plan


def deliver_notification(
    match: RecoveryMatch,
    *,
    post: Callable[..., Any] | None = None,
) -> tuple[int, str]:
    """Post only Apple's original envelope and return a redacted outcome."""

    if post is None:
        import requests

        post = requests.post
    response = post(
        FIXED_WEBHOOK_URL,
        headers={"Content-Type": "application/json"},
        json={"signedPayload": match.signed_payload},
        timeout=60,
    )
    try:
        payload = response.json()
        raw_result = payload.get("status") if isinstance(payload, dict) else None
    except (ValueError, AttributeError):
        raw_result = None
    result = (
        raw_result
        if raw_result in {"applied", "already_applied"}
        else "unexpected_response"
    )
    return int(response.status_code), result


def recover_purchases(
    *,
    fetcher: Callable[[int, int], list[dict[str, Any]]] = fetch_history,
    post: Callable[..., Any] | None = None,
    emit_progress: bool = False,
) -> list[tuple[str, int, str]]:
    """Resolve the complete plan, then deliver each signed payload exactly once."""

    plan = build_recovery_plan(fetcher=fetcher)
    if emit_progress:
        for item in plan:
            print(f"target={item.target.label} exact_unique_matches=1")

    outcomes: list[tuple[str, int, str]] = []
    for item in plan:
        status, result = deliver_notification(item.match, post=post)
        if emit_progress:
            print(
                f"target={item.target.label} delivery_http={status} "
                f"result={result}"
            )
        if status != 200 or result not in {"applied", "already_applied"}:
            raise RuntimeError(
                f"target={item.target.label}:delivery_not_applied:"
                f"http_{status}:result_{result}"
            )
        outcomes.append((item.target.label, status, result))
    return outcomes


def main() -> None:
    recover_purchases(emit_progress=True)


if __name__ == "__main__":
    main()
