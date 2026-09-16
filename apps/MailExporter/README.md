# MailExporter (SwiftUI)

## Build

```bash
./build.sh
open MailExporter.app
```

Produces a **self-contained** app: Swift UI + bundled `MailExporterEngine` (no Homebrew Python/`rg` at runtime). Signed with your Apple Development identity when available.

## Full Disk Access

Enable **only MailExporter** in System Settings → Privacy & Security → Full Disk Access, then quit and reopen the app.

## Window

One **Export** pane:

- Job list (scrolls if needed) with **Export**, **Show in Finder**, and **Edit** per job
- **Add Export** opens a sheet for criteria, output folder, include sent/bin, and name
- Always-visible drop zone at the bottom: Markdown → Apple Mail draft (never sends)
