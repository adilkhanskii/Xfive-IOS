#!/usr/bin/env python3
"""Stage or enable the production Kaspi Pay provider integration.

The script intentionally requires the Supabase service-role key through the
environment and never writes or prints it. Merchant identifiers are supplied by
Kaspi after onboarding; they must not be guessed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request


DEFAULT_SUPABASE_URL = "https://afwznqjpshybmqhlewmy.supabase.co"
DEFAULT_CALLBACK_URL = (
    "https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/kaspi-pay-provider"
)
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_-]{1,100}$")


def validate_identifier(label: str, value: str) -> str:
    if not IDENTIFIER_RE.fullmatch(value):
        raise ValueError(f"{label} has an unexpected format")
    return value


def build_payload(args: argparse.Namespace) -> dict[str, object]:
    if args.enable and not args.confirmed_by_kaspi:
        raise ValueError(
            "--enable requires --confirmed-by-kaspi after Kaspi registers the callback"
        )

    return {
        "p_service_name": validate_identifier("serviceName", args.service_name),
        "p_service_id": validate_identifier("serviceId", args.service_id),
        "p_account_parameter_id": validate_identifier(
            "account parameter ID", args.account_parameter_id
        ),
        "p_provider_callback_url": args.callback_url,
        "p_enabled": bool(args.enable),
    }


def request_json(
    url: str,
    service_role_key: str,
    *,
    method: str = "GET",
    payload: dict[str, object] | None = None,
) -> object:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "apikey": service_role_key,
            "authorization": f"Bearer {service_role_key}",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else None


def configure(args: argparse.Namespace) -> dict[str, object]:
    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    if not service_role_key:
        raise ValueError("SUPABASE_SERVICE_ROLE_KEY is required in the environment")

    base_url = args.supabase_url.rstrip("/")
    payload = build_payload(args)
    result = request_json(
        f"{base_url}/rest/v1/rpc/configure_kaspi_pay_integration",
        service_role_key,
        method="POST",
        payload=payload,
    )
    if result is not True:
        raise RuntimeError("Kaspi configuration RPC did not confirm the update")

    rows = request_json(
        f"{base_url}/rest/v1/kaspi_payment_settings"
        "?select=enabled,service_name,service_id,account_parameter_id,"
        "provider_callback_url,updated_at&singleton=eq.true&limit=1",
        service_role_key,
    )
    if not isinstance(rows, list) or len(rows) != 1:
        raise RuntimeError("Could not read back the Kaspi production settings")
    return rows[0]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stage or enable Kaspi Pay using identifiers issued by Kaspi."
    )
    parser.add_argument("--service-name", required=True)
    parser.add_argument("--service-id", required=True)
    parser.add_argument("--account-parameter-id", required=True)
    parser.add_argument("--supabase-url", default=DEFAULT_SUPABASE_URL)
    parser.add_argument("--callback-url", default=DEFAULT_CALLBACK_URL)
    parser.add_argument(
        "--enable",
        action="store_true",
        help="Enable customer orders after Kaspi has registered the callback.",
    )
    parser.add_argument(
        "--confirmed-by-kaspi",
        action="store_true",
        help="Required safety acknowledgement when --enable is used.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        settings = configure(args)
    except (ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"Kaspi activation failed: {error}", file=sys.stderr)
        return 1

    state = "enabled" if settings.get("enabled") else "staged_disabled"
    print(
        json.dumps(
            {
                "ok": True,
                "state": state,
                "callback": settings.get("provider_callback_url"),
                "updatedAt": settings.get("updated_at"),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
