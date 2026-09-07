# MailExporter (SwiftUI)

## Build

```bash
./build.sh
open MailExporter.app
```

Produces a **self-contained** app: Swift UI + bundled `MailExporterEngine` (no Homebrew Python/`rg` at runtime). Signed with your Apple Development identity when available.

## Full Disk Access

Enable **only MailExporter** in System Settings → Privacy & Security → Full Disk Access, then quit and reopen the app.

## Tabs

- **Config** — create/edit jobs and criteria; preview match count
- **Run** — export; shows `Name: N copied` and posts a notification
