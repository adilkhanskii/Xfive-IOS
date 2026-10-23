# Xfive marketing

Native iOS client (SwiftUI, iOS 16+) and Supabase backend.

## Current source and release evidence

- Canonical remote: `https://github.com/tooyakov-art/x5`.
- Bundle: `com.x5studio.app`; Apple app ID: `6764340680`.
- Submitted baseline: commit `512f546`, version **1.1.9 (239)**.
- As checked on **2026-09-07**, Apple: `WAITING_FOR_REVIEW`, build `VALID`,
  release `AFTER_APPROVAL` ([read-only audit at 10:23 UTC](https://github.com/tooyakov-art/x5/actions/runs/34111162162)).
- Current acceptance work: `codex/x5-ios-payments-239` in
  `work/x5-ios-payment-release`. Later commits on this branch are NOT automatically
  included in submitted build 239.
- Internal TestFlight **1.1.9 (240)**: runtime commit `6707cad`, `VALID` /
  `IN_BETA_TESTING` ([verified status](https://github.com/tooyakov-art/x5/actions/runs/34098808130)).
  Not yet attached to Apple Review; client-device payment acceptance remains open.
- The separate `work/x5` checkout has unpublished changes. Do not mix its
  Kaspi/course work into this payment release.

The living acceptance matrix, defects, proof and exact next step are in
[project-audit.md](docs/project-audit.md) and
[project-status.md](docs/project-status.md). Historic handoff documents are
not proof of the current deployment or working integrations.

## Layout

- `X5/`: native app, StoreKit purchase UI, courses, Hub, portfolio and AI clients.
- `X5Tests/`: behavioral XCTest and URLProtocol integration tests.
- `X5AcceptanceUITests/`: real simulator UI, dedicated review login, read-only.
- `supabase/functions/`: authenticated Edge Functions; provider secrets server-only.
- `supabase/migrations/`: immutable deployed migrations and forward-only changes.
- `supabase/tests/`: handler contracts and transaction/SQL tests.
- `diagnostics/x5-audit/`: isolated synthetic PostgreSQL acceptance reproduction.
- `project.yml`: authoritative XcodeGen project (Swift 5.9 language mode).
- `fastlane/`, `.github/workflows/`, `scripts/`: existing release automation.

Dependencies include GoogleSignIn, the pinned X5 TUSKit fork and
NextLevelSessionExporter. See `project.yml` and generated package resolution;
the app is not dependency-free.

## Build and verify

iOS needs macOS/Xcode; from Windows use the existing macOS GitHub Actions runner.
Use the workflow on the exact reviewed commit/branch, not an arbitrary copy.

```text
xcodegen generate
xcodebuild test -project X5.xcodeproj -scheme X5-Course-CI -destination 'platform=iOS Simulator,id=<simulator-id>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES
python -m unittest discover -s scripts/tests -p 'test_*.py'
cd supabase/functions/verify-app-store-transaction
deno test --frozen --allow-read
```

`gh workflow run ios-course-ci.yml --ref <reviewed-branch>` runs existing
server/source/XCTest checks; manual runs also execute read-only real UI checks.
UI credentials are included only in the test runner, masked in CI logs, never
in the shipped app. No real payment/generation is performed by these tests.
Use protected `X5_APP_REVIEW_EMAIL` / `X5_APP_REVIEW_PASSWORD` secrets. The
environment-gated UI job temporarily hydrates `.secrets/review-test/`, removes
the files afterward, and never uploads authenticated screenshots from a PUBLIC
repository. Normal application/unit builds do not need review credentials.
Fastlane metadata upload (including direct deliver) fails closed without both
in-memory credentials. Do not restore credential files from Git history.
Local read-only audit accepts environment variables from encrypted secret storage;
do not paste credentials into CLI arguments, documentation or the repository.
Simulator signing is intentional: the unsigned baseline returns Keychain
`errSecMissingEntitlement (-34018)` and cannot persist a real login. Do not work
around that by storing session tokens in plaintext. The export workflow also
rejects an IPA containing acceptance-test bundles or review-login txt resources.

## Release and payment boundaries

- Do not assume a push means publication. The established protected environment
  permits releases through `codex/x5-full-fix-20260801`; preserve its protection.
- Build/upload, attach metadata, audit and submit are separate workflows. Check
  the actual Apple version/build association and review state after each action.
- Credits in iOS use StoreKit consumables; the badge is a monthly subscription.
  Bank debit and Apple transaction verification are distinct pieces of evidence.
- TestFlight transactions are Sandbox and do not charge a real bank card.
  Ordinary Sandbox accounts must not receive spendable production credits;
  the dedicated App Review allowance is separately capped and isolated.
- Kaspi is outside the confirmed scope of this release.
- AI availability comes from authenticated server capabilities. A configured key
  or a successful health call is not proof of a completed generation.
- Never commit provider/signing keys or broaden production permissions for tests.
