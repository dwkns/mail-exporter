# MailExporter (SwiftUI)

## Build

```bash
./build.sh
open /Applications/MailExporter.app
```

Produces a **self-contained** app: Swift UI + bundled `MailExporterEngine` (no Homebrew Python/`rg` at runtime). Signed with your Apple Development identity when available.

## Full Disk Access

Enable **only MailExporter** in System Settings → Privacy & Security → Full Disk Access, then quit and reopen the app.

## Window

One **Export** pane. Empty title bar (traffic lights stay). In-pane heading **Mail Exporter** with the app icon.

- Job list (scrolls if needed) with **Export** plus an ellipsis for **Edit** and **Show in Finder**
- Header **+** opens New Export; **Export All** is the primary action
- Always-visible drop zone at the bottom: Markdown → Apple Mail draft (never sends)
