# Private client assets

`HomeApprovedReference.png.enc` is the AES-256-CBC encrypted copy of the exact
X5-approved Home artwork. Its plaintext must not be committed to this public
repository.

Trusted builds restore it with `scripts/decrypt_client_home_art.sh` using the
protected `X5_HOME_ART_KEY` GitHub Actions secret. The script verifies SHA-256
`c77a8588b7c98e831fe6e915c9bba83c9ee1f835b0452ef05455f8aa107f651b`
before Xcode can use the asset.

Encryption parameters: OpenSSL/LibreSSL `aes-256-cbc`, PBKDF2, SHA-256, 200,000
iterations, random salt. The approved plaintext remains only in trusted local
workspaces and ephemeral CI runners.
