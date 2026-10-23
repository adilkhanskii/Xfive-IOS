#!/usr/bin/env bash
#
# X5 — convert signing artifacts -> base64 -> upload to GitHub Secrets via gh.
# Run inside Git Bash on Windows from the repo root:
#
#     bash scripts/setup-secrets.sh
#
# Prereqs (do these first, see SUBMIT.md Phases 4-6):
#   _signing/distribution.cer            (downloaded from Apple Developer)
#   _signing/distribution.key            (generated already, do not lose)
#   _signing/profile.mobileprovision     (downloaded from Apple Developer)
#   _signing/AuthKey_<KEY_ID>.p8         (downloaded from App Store Connect)
#   gh CLI logged in (you already are)
#
# What this script does:
#   1. Builds dist.p12 from .cer + .key (asks for a password once)
#   2. base64-encodes the three artifacts
#   3. Uploads 7 GitHub repository secrets to the connected repo
#   4. Cleans up the .b64 staging files

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_DIR="$REPO_DIR/_signing"

cyan()  { printf "\033[36m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1" >&2; }

cyan "X5 GitHub Secrets bootstrap"
echo "Repo dir   : $REPO_DIR"
echo "Signing dir: $SIGN_DIR"
echo

# --- sanity checks ---
[[ -d "$SIGN_DIR" ]] || { red "Missing folder $SIGN_DIR — run openssl steps first"; exit 1; }

require() {
  local f="$1"; local hint="$2"
  if ! ls $SIGN_DIR/$f 1> /dev/null 2>&1; then
    red "Missing $SIGN_DIR/$f"
    red "  -> $hint"
    exit 1
  fi
}
require "distribution.key"        "should already exist (created earlier)"
require "distribution.cer"        "download from Apple Developer Portal after submitting distribution.csr"
require "profile.mobileprovision" "download from Apple Developer Portal after creating provisioning profile 'X5 App Store Profile'"
require "AuthKey_*.p8"            "download .p8 from App Store Connect -> Users and Access -> Integrations -> App Store Connect API"

P8_FILE=$(ls "$SIGN_DIR"/AuthKey_*.p8 | head -n1)
KEY_ID=$(basename "$P8_FILE" | sed -E 's/^AuthKey_(.+)\.p8$/\1/')
green "Found ASC API key: $P8_FILE  (Key ID: $KEY_ID)"

# --- ensure gh is ready ---
gh auth status >/dev/null 2>&1 || { red "gh is not logged in. Run: gh auth login"; exit 1; }
REPO_FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
if [[ -z "$REPO_FULL" ]]; then
  red "Could not detect a connected GitHub repo. Run from inside a cloned repo."
  exit 1
fi
green "Target repo: $REPO_FULL"
echo

# --- prompts ---
read -srp "Set a NEW strong password for dist.p12 (write it down): " P12_PASS; echo
[[ -n "$P12_PASS" ]] || { red ".p12 password cannot be empty"; exit 1; }

read -p "Issuer ID from App Store Connect API page (UUID): " ASC_ISSUER_ID
[[ -n "$ASC_ISSUER_ID" ]] || { red "issuer id required"; exit 1; }

# Random keychain password (used only inside the runner)
KEYCHAIN_PASS=$(openssl rand -hex 16)

cd "$SIGN_DIR"

# --- 1. build dist.p12 ---
cyan ""
cyan "Step 1: building dist.p12 from .cer + .key"
MSYS_NO_PATHCONV=1 openssl x509 -in distribution.cer -inform DER -out distribution.pem -outform PEM
MSYS_NO_PATHCONV=1 openssl pkcs12 -export \
  -inkey distribution.key \
  -in   distribution.pem \
  -out  dist.p12 \
  -name "Apple Distribution" \
  -password pass:"$P12_PASS"
green "  -> dist.p12 created"

# --- 2. base64 encode ---
cyan ""
cyan "Step 2: base64 encoding"
base64 -w 0 dist.p12                > dist.p12.b64
base64 -w 0 profile.mobileprovision > profile.mobileprovision.b64
base64 -w 0 "$P8_FILE"              > authkey.p8.b64
green "  -> .b64 staging files written"

# --- 3. upload secrets ---
cyan ""
cyan "Step 3: uploading 7 GitHub Secrets to $REPO_FULL"

upload_secret() {
  local name="$1"; local value="$2"
  printf "%s" "$value" | gh secret set "$name" --repo "$REPO_FULL" --body -
  green "  + $name"
}

upload_secret_file() {
  local name="$1"; local path="$2"
  gh secret set "$name" --repo "$REPO_FULL" < "$path"
  green "  + $name (from file)"
}

upload_secret_file "IOS_DIST_CERT_P12_BASE64"        "dist.p12.b64"
upload_secret      "IOS_DIST_CERT_PASSWORD"          "$P12_PASS"
upload_secret_file "IOS_PROVISIONING_PROFILE_BASE64" "profile.mobileprovision.b64"
upload_secret      "IOS_KEYCHAIN_PASSWORD"           "$KEYCHAIN_PASS"
upload_secret_file "ASC_API_KEY_BASE64"              "authkey.p8.b64"
upload_secret      "ASC_API_KEY_ID"                  "$KEY_ID"
upload_secret      "ASC_API_ISSUER_ID"               "$ASC_ISSUER_ID"

# --- 4. cleanup ---
cyan ""
cyan "Step 4: cleaning up base64 staging files"
rm -f dist.p12.b64 profile.mobileprovision.b64 authkey.p8.b64 distribution.pem
green "  -> done"

cyan ""
green "All 7 secrets are configured on $REPO_FULL."
echo
echo "Next: trigger the build with"
echo "    gh workflow run 'iOS build & TestFlight upload' --repo $REPO_FULL"
echo
echo "Or push any commit to main."
