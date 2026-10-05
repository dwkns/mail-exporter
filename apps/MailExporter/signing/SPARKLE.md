# Sparkle signing (Mac Mini only)

Developer ID, the Sparkle EdDSA **private** key, and notarization credentials live on **dwkns-mini-m1**. Never copy them onto a laptop or into git.

The public key is committed as `apps/MailExporter/sparkle-public-ed-key.txt` (`SUPublicEDKey`).

## On the Mini (once)

1. Sparkle 2.9.6 tools: `~/Library/Application Support/MailExporter/sparkle-tools` (`bin/generate_appcast`, `bin/sign_update`).
2. EdDSA private key file (mode `600`):

   `~/Library/Application Support/MailExporter/sparkle-ed25519-private.txt`

   Base64 of the 32-byte Ed25519 seed. `sign_update --ed-key-file` reads it. Do not `scp` this file.
3. Optional Keychain import (GUI session; SSH hits `errSecInteractionNotAllowed` / `-25308`):

   `sparkle-tools/bin/generate_keys --account MailExporter -f ~/Library/Application\ Support/MailExporter/sparkle-ed25519-private.txt`
4. Notarization profile (optional but needed for Gatekeeper):

   `xcrun notarytool store-credentials MailExporter --apple-id … --team-id LD2427W529`

## After each `v*` GitHub Release

CI already attached the helper-only `MailExporter-macOS-arm64.zip`. On the Mini:

```bash
./scripts/sparkle-publish-on-mini.sh vX.Y.Z
```

That re-signs the CI zip with Developer ID (helper-only entitlements), notarizes when the profile exists, EdDSA-signs the archive, and uploads `MailExporter-macOS-arm64-sparkle.zip` plus `appcast.xml` to the same tag. The CI zip is not replaced.

The app’s `SUFeedURL` is:

`https://github.com/dwkns/mail-exporter/releases/latest/download/appcast.xml`

Until that asset exists, Check for Updates falls back to the existing GitHub zip + SHA-256 path.
