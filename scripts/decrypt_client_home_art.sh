#!/usr/bin/env bash

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENCRYPTED_ART="$ROOT_DIR/PrivateAssets/HomeApprovedReference.png.enc"
readonly OUTPUT_ART="$ROOT_DIR/X5/Assets.xcassets/HomeApprovedReference.imageset/HomeApprovedReference.png"
readonly EXPECTED_SHA256="c77a8588b7c98e831fe6e915c9bba83c9ee1f835b0452ef05455f8aa107f651b"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [[ -f "$OUTPUT_ART" ]]; then
  if [[ "$(sha256_file "$OUTPUT_ART")" == "$EXPECTED_SHA256" ]]; then
    exit 0
  fi
  echo "Existing Home artwork does not match the approved SHA-256." >&2
  exit 1
fi

: "${X5_HOME_ART_KEY:?X5_HOME_ART_KEY is required to restore the approved Home artwork}"

readonly KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/x5-home-art-key.XXXXXX")"
readonly OUTPUT_TMP="${OUTPUT_ART}.tmp"
cleanup() {
  rm -f "$KEY_FILE" "$OUTPUT_TMP"
}
trap cleanup EXIT

umask 077
printf '%s' "$X5_HOME_ART_KEY" > "$KEY_FILE"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
  -in "$ENCRYPTED_ART" \
  -out "$OUTPUT_TMP" \
  -pass "file:$KEY_FILE"

if [[ "$(sha256_file "$OUTPUT_TMP")" != "$EXPECTED_SHA256" ]]; then
  echo "Decrypted Home artwork failed the approved SHA-256 check." >&2
  exit 1
fi

mv "$OUTPUT_TMP" "$OUTPUT_ART"
