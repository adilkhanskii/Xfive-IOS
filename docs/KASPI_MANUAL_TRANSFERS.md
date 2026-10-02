# Kaspi manual transfers (site checkout)

Kaspi has not issued the provider identifiers (`serviceName`, `serviceId`,
order parameter id) that confirm a payment automatically, so x5marketing.com
could not take money at all. This is the route that works today.

## How it works

1. The buyer picks a credit pack on the site and taps **Оплатить Kaspi**.
2. The site first tries the automatic provider flow. Only if the server answers
   `kaspi_pay_not_configured` does it fall back to a manual transfer, so the day
   Kaspi activates the provider integration the site switches back on its own
   with no code change and no release.
3. The manual panel shows the exact amount, the merchant's Kaspi number and a
   unique reference code `X5-XXXXXXXXXX`, each copyable, plus a button that
   opens Kaspi. The buyer sends the amount with the code in the comment.
4. The buyer taps **Я оплатил**; the order moves to `awaiting_review`. Nothing
   is granted at this point.
5. An X5 developer confirms the transfer. Credits are granted inside the same
   statement that closes the order, so a double click, a retry or two reviewers
   at once cannot grant twice.

There is no public Kaspi deep link that pre-fills a person-to-person transfer.
Pre-filling the amount is exactly what the provider integration buys, which is
why the amount is shown to copy instead.

## Enabling it in production

Apply the migration by hand (production migration history has diverged, so
`supabase db push` is unsafe; see docs/MIGRATION-HISTORY-2026-10-02.md for the
order and the history repair), then store the merchant requisites with the
service-role key. The key is read from the environment and never written to
the repository.

```powershell
supabase db query --linked -f supabase/migrations/20260903150000_kaspi_manual_transfers.sql
```

Approved transfers are granted as permanent credits (the same
`x5.permanent_credit_grant_user` flag the App Store and Google Play grants set),
so they never expire.

```powershell
$env:SUPABASE_SERVICE_ROLE_KEY = '<protected server key>'
curl -X POST "https://afwznqjpshybmqhlewmy.supabase.co/rest/v1/rpc/configure_kaspi_manual_transfers" `
  -H "apikey: $env:SUPABASE_SERVICE_ROLE_KEY" `
  -H "Authorization: Bearer $env:SUPABASE_SERVICE_ROLE_KEY" `
  -H "Content-Type: application/json" `
  -d '{"p_recipient_name":"ИП СЕЙДАХМЕТОВ","p_recipient_phone":"+7 700 774 4401","p_recipient_iban":"KZ04722S000022520163","p_enable":true}'
```

Turning it off later is the same call with `"p_enable": false`.

## Reviewing transfers

Both X5 developer accounts (`is_x5_developer()`) can call:

- `list_kaspi_manual_payments('awaiting_review')` — the queue, newest first.
- `review_kaspi_manual_payment(<payment id>, true, '<note>')` — confirm and grant.
- `review_kaspi_manual_payment(<payment id>, false, '<reason>')` — reject; the
  buyer sees the reason on the site.

Orders expire 24 hours after they are opened.

## Tests

`supabase/tests/20260903_kaspi_manual_transfers_test.sql` runs the whole flow on
a scratch database and asserts that checkout is closed until configured, that
the server owns the amount and the code, that submitting grants nothing, that a
buyer can neither approve their own transfer nor read the queue, that approval
grants exactly once, and that a rejection changes no balance.

Contract tests for the client live in `x5ssd/web/tests/kaspiCreditPayments.test.mjs`.
