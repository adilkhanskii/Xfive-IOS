"""Read current Apple KAZ consumable prices. Never writes to Apple or buys."""
import json
from datetime import datetime, timezone
from scripts.asc_configure_credit_store import AppStoreConnect, BUNDLE_ID, CREDIT_PACKS, active_manual_price


class ReadOnlyAppStoreConnect(AppStoreConnect):
    def request(self, method, path, **kwargs):
        if method != "GET" or kwargs.get("payload") is not None:
            raise RuntimeError("Read-only price audit refuses mutations")
        return super().request(method, path, **kwargs)


def audit(api, on_date=None):
    on_date = on_date or datetime.now(timezone.utc).date()
    apps = api.request("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}").get("data", [])
    if len(apps) != 1:
        raise RuntimeError("Expected exactly one X5 app")
    purchases = api.list_all(f"/v1/apps/{apps[0]['id']}/inAppPurchasesV2?limit=200")
    rows = []
    for pack in CREDIT_PACKS:
        matches = [p for p in purchases if p.get("attributes", {}).get("productId") == pack.product_id]
        if len(matches) != 1 or matches[0].get("attributes", {}).get("inAppPurchaseType") != "CONSUMABLE":
            raise RuntimeError(f"Missing or invalid consumable {pack.product_id}")
        purchase = matches[0]
        path = (f"/v1/inAppPurchasePriceSchedules/{purchase['id']}/manualPrices"
                "?filter[territory]=KAZ&fields[inAppPurchasePricePoints]=customerPrice"
                "&fields[inAppPurchasePrices]=startDate,endDate,inAppPurchasePricePoint"
                "&include=inAppPurchasePricePoint&limit=50")
        schedule = {"data": [], "included": []}
        seen = set()
        while path:
            if path in seen:
                raise RuntimeError("Repeated Apple pagination cursor")
            seen.add(path)
            page = api.request("GET", path)
            schedule["data"].extend(page.get("data", []))
            schedule["included"].extend(page.get("included", []))
            path = page.get("links", {}).get("next")
        current = active_manual_price(schedule, on_date=on_date)
        if current is None:
            raise RuntimeError(f"No current KAZ price for {pack.product_id}")
        row, price = current
        if price != pack.price_kaz:
            raise RuntimeError(f"{pack.product_id}: current {price} KZT, expected {pack.price_kaz} KZT")
        rows.append({"product": pack.product_id, "credits": pack.credits, "currency": "KZT",
                     "price": str(price), "state": purchase["attributes"].get("state"),
                     "start": row.get("attributes", {}).get("startDate"),
                     "end": row.get("attributes", {}).get("endDate"), "result": "PASS"})
    return {"checked_on": on_date.isoformat(), "scope": "Apple current KAZ prices; not bank debit", "rows": rows}


if __name__ == "__main__":
    print(json.dumps(audit(ReadOnlyAppStoreConnect()), indent=2))
