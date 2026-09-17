# iCloud provisioning stub

Tiny Xcode project used only by `build.sh` to create or refresh the Mac
Team Provisioning Profile for `com.dwkns.MailExporter` +
`iCloud.com.dwkns.MailExporter`.

The real app is still compiled by `build.sh` (`swiftc` + PyInstaller).
This stub is not shipped.

Requires Xcode → Settings → Accounts signed into team `LD2427W529`.
Ad-hoc and CI builds skip this and omit iCloud entitlements.
