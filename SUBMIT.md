# X5 — Submission walkthrough

> Goal: get **X5** approved on the App Store within 5–7 days, without owning a Mac.
> Build runs on **GitHub Actions macOS runner (free tier)**.
> Read top-to-bottom on submission day. Every step has a checkbox.

## Already done automatically

- ✅ Private code repo: https://github.com/tooyakov-art/x5
- ✅ Public site repo: https://github.com/tooyakov-art/x5site
- ✅ Live legal pages on GitHub Pages:
  - https://tooyakov-art.github.io/x5site/
  - https://tooyakov-art.github.io/x5site/privacy.html
  - https://tooyakov-art.github.io/x5site/terms.html
  - https://tooyakov-art.github.io/x5site/support.html
- ✅ Distribution key + CSR generated in `_signing/distribution.key` + `_signing/distribution.csr`
- ✅ Swift sources reference real Pages URLs
- ✅ `scripts/setup-secrets.sh` automates: cer→p12, base64, upload all 7 secrets via gh

You only need to do the manual web-UI steps below + run `setup-secrets.sh` once.

---

## What you need before you start

- Apple Developer account `h-a-n-1@mail.ru` with Team `F8LA8PC4U6` (✓ already have)
- A GitHub account + a private repo for this project
- Supabase access to `afwznqjpshybmqhlewmy`
- Cheap domain `x5studio.app` (optional but recommended — see Phase 9)

You do NOT need a Mac. Everything below works from Windows.

---

## Phase 1 — Apply Supabase migration (5 min)

App Review hard-rejects without working account deletion (Guideline 5.1.1(v)).

- [ ] Open https://supabase.com/dashboard/project/afwznqjpshybmqhlewmy/sql/new
- [ ] Paste full contents of [`supabase/001_delete_own_account.sql`](./supabase/001_delete_own_account.sql)
- [ ] Click **Run**
- [ ] Verify:
  ```sql
  select proname from pg_proc where proname = 'delete_own_account';
  ```
  Expected: one row.

---

## Phase 2 — Configure Apple Sign-In on Supabase (10 min)

Supabase needs to know how to verify Apple identity tokens.

- [ ] Go to https://supabase.com/dashboard/project/afwznqjpshybmqhlewmy/auth/providers
- [ ] Find **Apple** → toggle **Enabled**
- [ ] **Client IDs (for OAuth):** add `com.x5studio.app`
   *(this is the bundle ID; iOS native Sign in with Apple uses the bundle ID as audience)*
- [ ] Save

That is enough for native iOS sign-in. The Services ID / Secret Key fields are only needed if you want web Apple Sign-In, which we don't.

---

## Phase 3 — Register Bundle ID at Apple (10 min)

- [ ] https://developer.apple.com/account/resources/identifiers/list
- [ ] Click **+** → **App IDs** → Continue → **App** → Continue
- [ ] **Description:** `X5`
- [ ] **Bundle ID:** Explicit → `com.x5studio.app`
- [ ] **Capabilities:** ✅ **Sign in with Apple**  *(don't enable anything else for v1.0)*
- [ ] Continue → Register

---

## Phase 4 — Create the App in App Store Connect (15 min)

- [ ] https://appstoreconnect.apple.com/apps
- [ ] Click **+** → **New App**
- [ ] **Platforms:** iOS
- [ ] **Name:** `X5`  *(if taken, try `X5 — AI Captions`)*
- [ ] **Primary Language:** English (U.S.)
- [ ] **Bundle ID:** `com.x5studio.app — X5`
- [ ] **SKU:** `x5app001`
- [ ] **User Access:** Full Access → Create

Copy the numeric **App Store Connect App ID** from the URL (e.g. `https://appstoreconnect.apple.com/apps/1234567890`) — you'll use it in Phase 8.

> Created on 2026-04-28: app name `X5 — AI Captions` (plain `X5` was taken), SKU `x5studio001` (`x5app001` was taken), **ASC App ID = 6764340680**.

---

## Phase 5 — Generate signing certificate (15 min)

GitHub Actions needs a Distribution Certificate (`.p12`) and a Provisioning Profile (`.mobileprovision`).

You have two options:

### Option A — Generate on a borrowed Mac (10 min)

- Open Xcode on any Mac → Settings → Accounts → add `h-a-n-1@mail.ru`
- Manage Certificates → **+** → **Apple Distribution**
- Right-click → Export → password-protect → save `dist.p12`

### Option B — Generate without a Mac, fully online (15 min)

This is the route you'll likely take. Follow these substeps carefully.

#### 5.1 Create CSR online

A CSR is just a key pair signing request. You can generate one in OpenSSL on Windows:

```bash
# Open Git Bash on Windows, run:
openssl genrsa -out distribution.key 2048
openssl req -new -key distribution.key -out distribution.csr -subj "/emailAddress=h-a-n-1@mail.ru/CN=X5 Distribution/C=US"
```

This gives you `distribution.key` (keep secret) and `distribution.csr` (upload).

#### 5.2 Get the certificate

- [ ] https://developer.apple.com/account/resources/certificates/list
- [ ] Click **+**
- [ ] Choose **Apple Distribution** → Continue
- [ ] Upload `distribution.csr` → Continue
- [ ] Download the resulting `.cer` file → save as `distribution.cer`

#### 5.3 Convert to .p12

```bash
# In Git Bash:
openssl x509 -in distribution.cer -inform DER -out distribution.pem -outform PEM
openssl pkcs12 -export -inkey distribution.key -in distribution.pem -out dist.p12 -name "Apple Distribution"
# Set a strong password when prompted — write it down, you'll need it.
```

You now have `dist.p12` + a password.

#### 5.4 Create provisioning profile

- [ ] https://developer.apple.com/account/resources/profiles/list
- [ ] Click **+**
- [ ] Distribution → **App Store Connect** → Continue
- [ ] App ID → `com.x5studio.app` → Continue
- [ ] Certificate → select the one you just created → Continue
- [ ] **Provisioning Profile Name:** `X5 App Store Profile`  *(must match `ExportOptions.plist`)*
- [ ] Generate → Download → save as `profile.mobileprovision`

---

## Phase 6 — Create App Store Connect API Key for upload (5 min)

This lets the GitHub workflow upload builds to TestFlight without a password prompt.

- [ ] https://appstoreconnect.apple.com/access/integrations/api  (User Access → Integrations → App Store Connect API)
- [ ] Click **+** → name `X5 GitHub Upload`, access `App Manager`
- [ ] Generate → Download `.p8` file (you can only download once!) — save as `AuthKey_XXXXXXXXXX.p8`
- [ ] Note the **Key ID** (10 chars, e.g. `ABC123DEFG`) and the **Issuer ID** (UUID near the top of the page)

---

## Phase 7 — Set up GitHub repo + Secrets (15 min)

### 7.1 Push the code

```bash
cd C:/Projects/clients/adilkhan/x5
git init
git add .
git commit -m "Initial X5 native iOS app"
# Create a private repo on github.com first (e.g. tooyakov21/x5)
git branch -M main
git remote add origin git@github.com:tooyakov21/x5.git
git push -u origin main
```

### 7.2 Convert files to base64

GitHub Secrets need text. Run this in Git Bash:

```bash
base64 -w 0 dist.p12 > dist.p12.b64
base64 -w 0 profile.mobileprovision > profile.mobileprovision.b64
base64 -w 0 AuthKey_XXXXXXXXXX.p8 > authkey.p8.b64
```

Open each `.b64` in a text editor and copy the entire contents to the clipboard for the next step.

### 7.3 Add Secrets in GitHub

Go to your repo → **Settings → Secrets and variables → Actions → New repository secret**. Add **all 6**:

| Name | Value |
|------|-------|
| `IOS_DIST_CERT_P12_BASE64` | contents of `dist.p12.b64` |
| `IOS_DIST_CERT_PASSWORD` | the .p12 password from Phase 5.3 |
| `IOS_PROVISIONING_PROFILE_BASE64` | contents of `profile.mobileprovision.b64` |
| `IOS_KEYCHAIN_PASSWORD` | any random string (used only inside the runner) |
| `ASC_API_KEY_BASE64` | contents of `authkey.p8.b64` |
| `ASC_API_KEY_ID` | the 10-char Key ID from Phase 6 |
| `ASC_API_ISSUER_ID` | the Issuer UUID from Phase 6 |

---

## Phase 8 — Trigger the first build (25 min)

- [ ] GitHub repo → **Actions** tab → `iOS build & TestFlight upload` workflow → **Run workflow** → branch `main`
- [ ] Wait ~15–20 minutes
- [ ] On success: artifact `X5-ipa` appears, AND the workflow uploads to TestFlight via altool

If the build fails:
- Check the failed step's log
- 90% of first-run failures are signing — verify all 6 secrets are correct, especially the .p12 password and that the profile name matches `ExportOptions.plist` (`X5 App Store Profile`)

After the upload succeeds:
- [ ] Wait ~10 minutes for App Store Connect to finish processing the build
- [ ] Open https://appstoreconnect.apple.com/apps/<your-app-id>/distribution → you should see the build appear under TestFlight

---

## Phase 9 — Privacy Policy + Terms hosting (30 min)

Apple requires a working Privacy URL. Cheap path:

- [ ] Buy `x5studio.app` on Namecheap (~$15/year) OR pick a free subdomain
- [ ] Use a static page generator — easiest is **GitHub Pages**:
  - Create `x5studio.github.io` repo with `privacy.html`, `terms.html`, `index.html`, `support.html`
  - Settings → Pages → Source = main → Save → URL becomes `https://<owner>.github.io/x5studio`

Skeleton privacy policy (paste into `privacy.html`):

```
X5 Privacy Policy
Last updated: April 28, 2026

We collect: email address, name, and an internal user ID — only to authenticate
your account. We do not track you, do not show ads, and do not share your data
with third parties.

Sign in with Apple is processed by Apple. Authentication tokens are stored
securely on Supabase (United States, AWS).

You can delete your account and all associated data at any time from
Profile -> Delete Account inside the app, or by emailing support@x5studio.app.

Contact: support@x5studio.app
```

If you don't own `x5studio.app`, change the URL in:
- `X5/Views/LoginView.swift` — `Privacy Policy` Link
- `X5/Views/ProfileView.swift` — three Link destinations
- `App Store Connect → App Information → Privacy Policy URL` (Phase 10)

---

## Phase 10 — App Store Connect metadata (45 min)

### 10.1 App Information

- [ ] **Subtitle:** `AI captions in seconds`
- [ ] **Category:** Primary = Productivity, Secondary = Business
- [ ] **Content Rights:** "Does not contain, show, or access third-party content" → **checked**
- [ ] **Age Rating:** answer all No → 4+
- [ ] **Privacy Policy URL:** `https://x5studio.app/privacy` (or your GH Pages URL)

### 10.2 Pricing and Availability

- [ ] Price: **Free**
- [ ] Availability: **All countries** (or restrict to RU, KZ, US for first release)

### 10.3 App Privacy

Click **Edit** in the App Privacy block. Declare exactly:

- [ ] Data Collected:
  - **Email Address** — Linked to user, not used for tracking, purpose: App Functionality
  - **Name** — Linked to user, not used for tracking, purpose: App Functionality
  - **User ID** — Linked to user, not used for tracking, purpose: App Functionality
- [ ] No tracking, no analytics, no ads

### 10.4 Version 1.0 page

- [ ] **Promotional Text:** `Generate marketing captions in seconds — pick a topic, choose a tone, copy the result.`
- [ ] **Description:**
  ```
  X5 is a focused AI caption writer for marketing professionals.

  Workflow:
  • Type your topic
  • Pick a tone — Friendly, Pro, or Funny
  • Tap Generate
  • Five tailored captions appear instantly
  • Copy the one you like

  No ads, no tracking, no clutter. Sign in with Apple keeps your account
  secure and never shares your real email with us.
  ```
- [ ] **Keywords:** `marketing,captions,ai,content,copywriting,instagram,tiktok,linkedin,social,writer`
- [ ] **Support URL:** `https://x5studio.app/support`
- [ ] **Marketing URL:** `https://x5studio.app`

### 10.5 Screenshots

3–10 screenshots required for **6.7"** (iPhone 16 Pro Max) and **6.5"** (iPhone 11 Pro Max).

Easiest path without a Mac:
- Ask a friend to grab screenshots on a real iPhone after installing via TestFlight (Phase 8 made the build available there)
- OR use https://www.figma.com / https://shotbot.io / https://previewed.app to mock screenshots from your design

Required content:
- Login screen (Sign in with Apple visible)
- Main screen with empty state
- Main screen with results filled in
- Profile screen (with Delete Account row visible)

**Critical rule:** screenshots should reflect what the app actually does — caption generation in 5 different examples plus the Profile / Sign-in flows.

### 10.6 App Review Information *(this is what saves you)*

- [ ] **Sign-in required:** Yes
- [ ] **Note about demo account:**
   You don't need a static demo account because the reviewer can use their own
   Apple ID via Sign in with Apple. State this in Notes.

- [ ] **Notes for review:**
  ```
  Hello App Review Team,

  X5 is a free native iOS app that generates marketing captions on-device
  using a built-in template engine. It does not contain in-app purchases,
  subscriptions, advertisements, or external payment links.

  Sign-in: Sign in with Apple is the only sign-in method. The reviewer's
  Apple ID can be used directly — no demo account needed.

  How to test:
  1. Launch the app.
  2. Tap "Sign in with Apple". Approve with Face ID / passcode.
  3. On the main screen, type any topic (e.g. "opening a coffee shop").
  4. Pick a tone (Friendly / Pro / Funny).
  5. Tap "Generate". Five captions appear.
  6. Tap "Copy" on any caption to copy it to clipboard.

  Account deletion (Guideline 5.1.1(v)):
  1. Tap the profile icon in the top-right of the main screen.
  2. Scroll to "Danger zone" section.
  3. Tap "Delete Account".
  4. Confirm in the first alert ("Continue").
  5. Confirm again in the final alert ("Delete forever").
  Result: account is permanently deleted via the public.delete_own_account()
  Supabase RPC. The user is signed out and all server-side rows tied to the
  Supabase auth.uid() are removed. The flow takes ~3 seconds.

  No third-party copyrighted content is downloaded, saved, or accessed.
  No external payment processors are referenced anywhere in the app.
  Sign in with Apple is implemented per Guideline 4.8.

  Privacy: https://x5studio.app/privacy
  Terms:   https://x5studio.app/terms
  Support: support@x5studio.app

  Thank you.
  ```

- [ ] **Contact Information:** your name, email, phone

### 10.7 Build

- [ ] Scroll to **Build** section → click **+** → select the build that GitHub Actions uploaded in Phase 8

### 10.8 Submit

- [ ] Top-right **Add for Review**
- [ ] Confirm
- [ ] Status flips to **Waiting for Review**

---

## Phase 11 — Wait & monitor (1–3 days)

- Apple typically responds in 24–72 hours
- If approved → set release type to manual, then release when ready
- If rejected → the response message tells you exactly why; reply within 24h with a fix

### Likely rejections (and the fix)

| Guideline | Likely cause | Fix |
|-----------|--------------|-----|
| 4.2 Minimum Functionality | Reviewer thinks the app is too thin | Reply explaining the on-device template engine, attach screen recording showing 5 different generations |
| 5.1.1(v) Account Deletion | Reviewer can't find / use it | Reply with screen recording of the full delete flow |
| 4.8 Sign in with Apple | Already implemented — reply pointing to LoginView code path |
| 2.1 Crash | Real bug | Check the crash log they attach, fix in code, push to main, GH Actions builds new version, resubmit |

---

## Phase 12 — Update cadence after launch

**Once v1.0 is live**, ship one update per week. Updates are reviewed much more leniently — usually 1 day.

Bump version + build before each `git push`:

```yaml
# project.yml
settings:
  base:
    MARKETING_VERSION: "1.1.0"   # ← bump this
    CURRENT_PROJECT_VERSION: "2" # ← bump this
```

Suggested progression:

| Version | What ships |
|---------|------------|
| **v1.0** | Caption generator (templates) + Apple Sign-In + Delete Account |
| v1.1 | Replace template engine with real Gemini API via Supabase RPC |
| v1.2 | Add "Content Ideas" tool — different angle, same writing-tools category |
| v1.3 | Add local history (in-memory or UserDefaults) |
| v1.4 | Add hashtag generator |
| v1.5 | Push notifications (contextual prompt) |
| v1.6 | AI rewrite / tone-shift tool |
| v1.7 | Multi-language support |
| v1.8 | Optional Pro tier (longer outputs, more templates) — IAP |
| v1.9+ | More tools in the AI-writing category (slogan generator, audience-persona helper, etc.) |

X5 stays in the **AI writing tools** category. It is not merged with or transformed into any other product, regardless of what other apps live under the same Team.

Each step: small, focused, low risk. Apple reviews subsequent updates in hours, not days.

---

## Daily commands cheat-sheet

```bash
# trigger a new build
git commit --allow-empty -m "rebuild" && git push

# regenerate icon
node scripts/gen-icon.mjs

# pull latest .ipa locally (after Actions finishes)
gh run download <run-id> -n X5-ipa
```

---

## Appendix — what's NOT in v1.0 (intentional)

- ❌ In-App Purchase
- ❌ Push notifications
- ❌ Camera, microphone, photo library access
- ❌ Real AI API calls (templates only — adds in v1.1)
- ❌ History (adds in v1.3)
- ❌ Email/Password sign-in (Apple Sign-In is enough)
- ❌ WebView of any kind
- ❌ Third-party SDKs (no Supabase SDK either — direct REST)

Each absence is deliberate — every removed feature is one less reason for App Review to push back.
