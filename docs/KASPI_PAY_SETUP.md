# Kaspi Pay status and activation

## Current production state

- The official Kaspi partnership application for X Five was submitted on
  2026-08-25. Kaspi returned: the application is being processed and a manager
  will contact the applicant within one month.
- The production callback is deployed at
  `https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/kaspi-pay-provider`.
- Its allowlist is explicitly restricted to the Kaspi provider IP published in
  the official integration guide (`194.187.247.152`). Requests from other IPs
  return `403`.
- The production integration remains disabled until Kaspi issues the merchant
  `serviceName`, `serviceId`, and order/account parameter ID and registers the
  callback. These identifiers must not be guessed.

## Implemented checkout

- Packages and exact amounts are owned by the server: 1,000 / 2,000 / 5,000
  credits cost 1,000 / 2,000 / 5,000 KZT.
- One customer tap creates a unique X5 order and opens the official Kaspi
  universal link with the same amount and order code.
- Kaspi `check` and `pay` callbacks validate the order and amount. A successful
  callback grants credits atomically; repeats cannot grant credits twice.
- Refunds are recorded and reverse the credited balance once.

## Activation after the Kaspi manager responds

Kaspi must provide:

1. `serviceName`;
2. `serviceId`;
3. order/account parameter ID;
4. confirmation that the callback above is registered and the exact `amount`
   URL parameter is enabled.

First stage the values while customer orders stay disabled:

```powershell
$env:SUPABASE_SERVICE_ROLE_KEY = '<protected server key>'
python scripts/kaspi_activate.py `
  --service-name '<Kaspi serviceName>' `
  --service-id '<Kaspi serviceId>' `
  --account-parameter-id '<Kaspi parameter ID>'
```

After Kaspi confirms the callback, enable the integration:

```powershell
python scripts/kaspi_activate.py `
  --service-name '<Kaspi serviceName>' `
  --service-id '<Kaspi serviceId>' `
  --account-parameter-id '<Kaspi parameter ID>' `
  --enable --confirmed-by-kaspi
```

Then complete one real 1,000 KZT order and verify that the payment is confirmed
and exactly 1,000 credits are granted once. Repeat the same callback to verify
idempotency before opening Kaspi checkout to all eligible users.

## Store boundary

External payment for digital credits must not be exposed in the public iOS app
unless the App Store rules and required entitlement allow it. Keep Kaspi limited
to internal testing/web while the current App Review is active. Store billing
remains the public iOS purchase route.
