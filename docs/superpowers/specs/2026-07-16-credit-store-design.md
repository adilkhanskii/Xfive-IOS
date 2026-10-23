# X Five Credit Store Design

## Goal

Replace the public Pro-subscription card with a simple credit store on iOS and Android. Customers can buy one-time packs of 1,000, 2,000, or 5,000 credits. Profile verification remains a separate auto-renewing subscription at 1,000 KZT per month.

## Product model

- Credit packs are repeatable consumable in-app purchases. Pack value and price are paired as 1,000/1,000 KZT, 2,000/2,000 KZT, and 5,000/5,000 KZT.
- Verification is the only newly promoted recurring subscription and never grants credits.
- Existing Lite, Pro, and Max subscriptions remain recognized and restorable until they expire, but are hidden from the new store. Existing entitlements are not revoked.
- A top-up changes only the shared `profiles.credits` balance and its purchase ledger. It does not change `plan`, subscription dates, or verification.
- Creator tools must not require a newly sold Lite/Pro/Max subscription after those plans are hidden. Usage continues to be controlled by authentication, the existing credit costs, and feature-specific rules; legacy plan state remains only for existing entitlements and management.

## User experience

- Every profile shows a `Магазин` card with the three pack amounts and current balance.
- Opening it shows three one-time purchase buttons and explicitly says that credits are added once and remain on the account.
- `Получить галочку` is a separate profile card and screen displaying 1,000 KZT/month, renewal terms, restore, and subscription management.
- The same information architecture and product amounts are used by the native iOS app and Android WebView app.
- Legacy subscription management remains available in Settings for existing subscribers.

## Purchase integrity

- Apple and Google signed purchase identifiers are verified server-side.
- The server derives the credit amount from an allowlisted product ID; clients cannot submit an amount.
- A unique transaction/purchase-token ledger provides exact-once crediting. Replays return success without adding credits again, and a purchase cannot be claimed by another user.
- iOS finishes a consumable only after the server confirms delivery; unfinished transactions are retried after sign-in/relaunch.
- Android verifies the Play purchase before consuming it; legacy subscriptions remain restorable, while consumables are not presented as restorable.

## Store products

| Platform | Product | Type |
| --- | --- | --- |
| iOS | `com.x5studio.app.credits.1000` | Consumable |
| iOS | `com.x5studio.app.credits.2000` | Consumable |
| iOS | `com.x5studio.app.credits.5000` | Consumable |
| iOS | `com.x5studio.app.verified.monthly` | Auto-renewable, 1,000 KZT/month |
| Android | `x5_credits_1000_v2` | One-time consumable |
| Android | `x5_credits_2000_v2` | One-time consumable |
| Android | `x5_credits_5000_v2` | One-time consumable |
| Android | `x5_verified_monthly_v2` | Subscription, 1,000 KZT/month |

## Compatibility and release

- Both clients use the existing shared Supabase profile balance.
- New store products must exist and be active in App Store Connect / Google Play Console before sandbox or internal-track purchases can succeed.
- UI and server changes are covered by catalog, routing, idempotency, cross-user, and type/build checks before release.
