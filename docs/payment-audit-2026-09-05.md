# Payment incident audit — 2026-09-05

## Result

No current free-credit exploit was reproduced or established. Do not describe
this audit as a new payment fix or a new iOS release. Version 1.1.8/build 238 is
already READY_FOR_SALE. Do not remove user balances just because a bank charge
was not observed: the disputed transactions exist directly in Apple's
Production API and currently have no revocation.

## Evidence

- Read the confirmed Adilkhan chat through current-clients-whatsapp-baileys only.
  No messages sent. September 3 text says another account receives credits
  without a bank debit. This is newer than the initial August complaint.
- September 2 payment video (message 2A734034453660BF1BB7) shows Apple sheets
  for 2,000 X5 Credits at 2,000 KZT and 5,000 X5 Credits at 5,000 KZT.
  A separate bank notification says APPLE.COM/BIL 3,990 KZT, insufficient funds;
  Apple displays "Your payment method was declined". Sampled frames retain
  balance 24,028. This video does not establish a balance increase on rejection.
  It does not identify which Apple order caused the 3,990 KZT bank attempt.
- Live Supabase consumable ledger: 11 Production purchases, total 18,000 credits,
  first August 31, last September 3. Breakdown: 7 × 1,000; 3 × 2,000; 1 × 5,000.
- Sandbox review ledger: 22 historical rows, 21,000 credits, latest August 16.
  Current allowlist contains only the canonical app-review account, enabled,
  account_kind=app_review, credit cap 10,000. No ordinary-user allowance.
- Direct mint functions and all inspected legacy/verified grant functions deny
  EXECUTE to both anon and authenticated roles. Do not widen these grants.
- Direct Apple Production GET transaction lookups for the four purchases on
  September 2–3 returned 1,000 / 2,000 / 1,000 / 2,000 KZT, quantity 1, KAZ,
  with null revocationDate/revocationReason. Full transaction IDs and account
  tokens intentionally omitted here. These are Apple's response data over
  authenticated HTTPS; the diagnostic script does not replace grant-time JWS
  cryptographic verification.
- App Store Connect: correct Production/Sandbox V2 notification URL; 1.1.8
  READY_FOR_SALE; release audit 0 issues, 4 warnings about subscription review
  screenshots that the audit cannot confirm.
- Notification endpoint rejects malformed signed payload with HTTP 400.
  No consumable refund rows currently exist. A live refund was not fabricated
  or requested, so end-to-end real refund settlement is not claimed tested.

## Reproducible audit

Commit 67444de adds a read-only, bounded direct Apple transaction lookup and
an audit_payments action to the existing release audit workflow. It changes no
balances, does not replay events, logs no JWS, and masks transaction identity.

Successful live run:
https://github.com/tooyakov-art/x5/actions/runs/33958706358

49 local Python checks passed: payment source contracts, purchase lifecycle,
credit catalog, notification configuration, sandbox audit, new lookup tests.
These are not a replacement for an on-device bank purchase test.

## Financial boundary and remaining uncertainty

Production transaction confirmation is not a bank-settlement receipt. Apple's
price documentation explicitly directs accounting users to financial reports:
https://developer.apple.com/documentation/AppStoreServerAPI/price

Apple documents unpaid previous purchases and payment-method failures:
https://support.apple.com/en-us/118284

The exact 3,990 KZT charge and whether the client's bank eventually debited a
particular order remain unverified. That requires the customer's Apple purchase
history/bank record or Apple billing support. Do not call it proven debt for a
specific order, assert the client is wrong, promise bank collection, or revoke
valid credits based solely on a missing immediate bank push notification.

No new iOS binary submitted during this audit: no app-level defect explaining
this complaint has been established, and the currently approved release is live.
