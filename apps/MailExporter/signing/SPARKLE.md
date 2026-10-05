# Updates

The app on the Mac you use is updated in place by `apps/MailExporter/build.sh`. That keeps the stamp macOS already approved, so disk access is not asked for again.

A download for another Mac is a separate file. It is signed with Developer ID and is not copied onto the app you already use.

Publish that download from any Mac that already has both of these:

- Developer ID Application: Darrell Wilkins (LD2427W529)
- `~/Library/Application Support/MailExporter/sparkle-ed25519-private.txt`

Sparkle’s `sign_update` and `generate_appcast` are in `apps/MailExporter/vendor/sparkle/bin`.

```bash
./scripts/sparkle-publish-on-mini.sh vX.Y.Z
```

The script name still says mini. The Mini does not have to be involved. Nobody needs to sit at a keyboard. The script does not replace `/Applications/MailExporter.app`.

Notarization runs only when a keychain profile named `MailExporter` is already stored. Without it, the download is still signed, and another Mac may ask the person to confirm before opening it the first time.
