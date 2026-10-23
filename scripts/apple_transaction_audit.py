"""Read-only Apple transaction lookup. Never grants, refunds, or replays purchases.

The response is fetched directly from Apple's authenticated HTTPS endpoint. JWS
decoding here is diagnostic only, not the cryptographic verifier used for grants.
Transaction data is NOT evidence of bank settlement; use financial reports for it.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from decimal import Decimal

from scripts.apple_notification_replay import _apple_token, decode_jws_payload

BUNDLE_ID = "com.x5studio.app"
URL = "https://api.storekit.apple.com/inApps/v1/transactions/"


def parse_ids(value: str) -> list[str]:
    ids = value.split(",")
    if not 1 <= len(ids) <= 10 or any(not re.fullmatch(r"[0-9]{5,30}", x.strip()) for x in ids):
        raise ValueError("Expected 1–10 comma-separated numeric transaction IDs")
    return list(dict.fromkeys(x.strip() for x in ids))


def summarize(payload: dict, expected_id: str) -> dict:
    if (payload.get("bundleId") != BUNDLE_ID
            or payload.get("transactionId") != expected_id
            or payload.get("environment") != "Production"):
        raise ValueError("Apple transaction identity/environment mismatch")
    price = payload.get("price")
    if price is not None and (type(price) is not int or price < 0):
        raise ValueError("Invalid Apple price")
    return {
        "transaction_fingerprint": hashlib.sha256(expected_id.encode()).hexdigest()[:16],
        "source": "Apple Production API (not bank settlement)",
        "product": payload.get("productId"),
        "price": str(Decimal(price) / 1000) if price is not None else None,
        "currency": payload.get("currency"),
        "storefront": payload.get("storefront"),
        "quantity": payload.get("quantity"),
        "purchase_date_ms": payload.get("purchaseDate"),
        "revocation_date_ms": payload.get("revocationDate"),
        "revocation_reason": payload.get("revocationReason"),
    }


def main() -> None:
    import requests
    ids = parse_ids(os.environ.get("TRANSACTION_IDS", ""))
    token = _apple_token()
    for transaction_id in ids:
        response = requests.get(
            URL + transaction_id,
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
            allow_redirects=False,
        )
        if response.status_code != 200:
            raise RuntimeError(f"Apple transaction lookup HTTP {response.status_code}; no balances changed")
        payload = decode_jws_payload(response.json()["signedTransactionInfo"])
        print(json.dumps(summarize(payload, transaction_id), ensure_ascii=False))


if __name__ == "__main__":
    main()
