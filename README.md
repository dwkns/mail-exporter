# MailExporter

Criteria-based export of Apple Mail messages to `.eml` files — without relying on Mail smart folders.

Define jobs (a name, match rules, and an output folder). MailExporter scans `~/Library/Mail`, copies matching messages, and keeps an incremental export so later runs only pick up new mail. It never deletes messages from Apple Mail.

An MCP server (`mail-exporter`) lets Cursor, Claude Desktop, and Claude Cowork list jobs, refresh exports, and read messages. It never sends mail.

## Requirements

- macOS (reads Apple Mail’s on-disk store)
- **Full Disk Access** for whichever app actually scans Mail (see [Permissions](#permissions))
- Python 3.10+ for the CLI and MCP server (not needed if you use the installed app helper)
- Xcode command-line tools if you build the Mac app

## Permissions

macOS blocks `~/Library/Mail` unless the **running app** has Full Disk Access:

System Settings → Privacy & Security → Full Disk Access

| How you run it | Grant access to |
|----------------|-----------------|
| MailExporter.app | **MailExporter** |
| `python3 -m engine` from Terminal | **Terminal** (or iTerm) |
| MCP inside Cursor | **Cursor** |
| MCP inside Claude Desktop / Cowork | **Claude** |

Quit and reopen the app after toggling access. Automation → Mail is required for drafts.

## Mac app

```bash
./apps/MailExporter/build.sh
open /Applications/MailExporter.app
```

The build produces a self-contained app: Swift UI plus a bundled `MailExporterEngine` (no Homebrew Python or `rg` at runtime).

- **Export** — one pane: job list (scrolls) plus an always-visible drop zone at the bottom. Add/Edit open a sheet. Drop Markdown to open an Apple Mail **draft** (never sends). The window title bar is empty (traffic lights stay); the in-pane heading is **Mail Exporter** with the app icon.

Jobs are stored in the private iCloud container `iCloud.com.dwkns.MailExporter` when this Mac’s signed build has the iCloud entitlement. Otherwise they stay at:

```text
~/Library/Application Support/MailExporter/jobs.json
```

CLI and MCP follow the same file the app last wrote (pointer at `~/Library/Application Support/MailExporter/jobs-location`).

Each export folder looks like this (MailExporter creates `Drafts/` and `Sent/`):

```text
<outputDir>/
  *.eml                 exported messages
  .exported-ids.json    incremental state — do not delete unless a full re-export
  _how_to_use.md        notes for an AI assistant (rewritten when the app's guide changes)
  Attachments/<id>/     files extracted next to the `.eml`
  Drafts/               Markdown the AI writes before the mail is known to be sent
  Sent/                 those Markdown files after a sent copy appears in the export
```

## Engine CLI

From the repository root:

```bash
python3 -m engine seed          # example jobs (edit From addresses before a real export)
python3 -m engine list
python3 -m engine export --dry-run --job-name DHL
python3 -m engine export --json --job-name DHL
python3 -m engine append-draft Drafts/001_who_subject.md   # Mail draft only — never sends
```

From the **installed app** (no Python, what Cursor/Claude should run when you say “send it”):

```bash
/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine append-draft /absolute/path/to/Drafts/001_who_subject.md
```

That opens an Apple Mail **draft**. It never sends. `draft` is an alias for `append-draft`.

`--force-full` wipes existing `.eml` files for that job and re-exports.

## Tests

Hermetic unit tests (no Mail GUI or network). From the repository root:

```bash
.venv/bin/pip install -r requirements-dev.txt   # once
.venv/bin/pytest -q
```

## Match rules

Clauses in a group with `"conjunction": "all"` are **AND**. Multiple `values` in one clause are **OR**.

```json
{
  "conjunction": "all",
  "conditions": [
    { "field": "from", "op": "is", "values": ["xxx@dhl.com", "yyy@dhl.com"] },
    { "field": "date", "op": "after", "date": "2026-03-04" }
  ]
}
```

Text fields: `from`, `to`, `cc`, `recipient`, `subject`, `body`, `entire`.  
Text ops: `contains`, `is`, `does_not_contain`.  
Date ops: `after`, `before`.

## MCP server

The local stdio server `mailexporter_mcp` talks to the same `jobs.json` as the Mac app. It does **not** send Mail to the internet. Keep it as a local process — do not register it as a public / remote Claude connector.

### Quickest setup (installed Mac app — no Python)

If `MailExporter.app` is in `/Applications`:

```json
{
  "mcpServers": {
    "mail-exporter": {
      "command": "/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine",
      "args": ["mcp"]
    }
  }
}
```

Or MailExporter → Settings → Advanced → Install mail-exporter MCP.

### Development setup (from source venv)

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-mcp.txt
PYTHONPATH="$(pwd)" .venv/bin/python -m mailexporter_mcp
```

### Tools

| Tool | Use when |
|------|----------|
| `list_jobs` | See jobs and their export folders |
| `list_messages` | List `.eml` files with From / Subject / Date / Message-ID |
| `read_message` | Read headers + body of one `.eml` |
| `list_drafts` | Inventory `Drafts/` and `Sent/` Markdown |
| `create_job` / `edit_job` | Set up or change an export |
| `compose_draft` | Open a Mail draft from Markdown (AppleScript) |
| `check_matches` | Dry-run: how many Mail messages currently match |
| `export_job` | Refresh the folder from Apple Mail (incremental unless `force_full`) |
| `clear_target` | Delete exported `.eml` files (debug / full redo) |
| `write_howto` | Refresh `_how_to_use.md` in one folder, or every export folder if no job is given |

Typical flow: `list_jobs` → `list_messages` / `read_message` → write a numbered `.md` in `Drafts/` → `compose_draft` → `export_job` later. Matching Markdown moves to `Sent/` once a sent copy is in the export.

`read_message` only reads `.eml` files under a configured job `outputDir`. `clear_target` only clears folders that look like MailExporter exports (marker files present).

## Markdown drafts (for AI)

An assistant helping with this mailbox should keep outgoing mail as Markdown files next to the export, not in the `.eml` root.

**Where**

| Folder | Meaning |
|--------|---------|
| `<outputDir>/Drafts/` | Composing, waiting to send, or not yet confirmed sent |
| `<outputDir>/Sent/` | Confirmed sent because a matching `.eml` showed up after `export_job` |

**Filenames:** `NNN_who_subject.md`

- `NNN` — three-digit sequence (`001`, `002`, …). Next number after the highest already used in **both** `Drafts/` and `Sent/`.
- `who` — who it is to (name or email local-part), lowercase, hyphens, no `@`.
- `subject` — enough of the subject to recognise the mail (strip `Re:` / `Fwd:`).

Examples: `001_supplier_inquiry.md`, `014_contractor_quote.md`.

Keep the same filename when moving `Drafts/` → `Sent/`. Move (do not copy or delete) only when an exported `.eml` matches To / Subject / thread — the job must include Sent mail. If it is unclear, leave the file in `Drafts/`.

Details and the Markdown front-matter format are in `_how_to_use.md` inside each export folder.

---

### Cursor

Project config (this repo already has `.cursor/mcp.json`) or a global config at `~/.cursor/mcp.json`. Prefer the installed helper command above. Reload the window after editing MCP config.

Grant **Cursor** Full Disk Access if `export_job` / `check_matches` cannot read Mail.

Ask Agent things like: “List MailExporter jobs” or “Read the latest messages in the DHL export.”

---

### Claude Desktop

1. Install [Claude Desktop](https://claude.ai/download).
2. Open **Claude → Settings → Developer → Edit Config** (`~/Library/Application Support/Claude/claude_desktop_config.json`).
3. Merge the installed-helper `mcpServers` block above (keep any servers you already have).
4. Fully quit Claude Desktop (Cmd-Q) and reopen it.
5. Grant **Claude** Full Disk Access if exports cannot read Mail.

Claude Desktop only understands local stdio servers in that JSON file. Use absolute paths.

---

### Claude Cowork

MailExporter must stay on your Mac (it reads `~/Library/Mail`). Cowork can use it as a **local connector**, not as a cloud/remote custom connector.

1. Install the server in **Claude Desktop** first. Cowork does not have a separate MCP config file.
2. Open the latest Claude Desktop app. In the message box, choose **Cowork**.
3. Click **+** → **Connectors** and enable **mail-exporter** for that session.
4. Keep Claude Desktop running.

Do **not** add this server under **Customize → Connectors → Add custom connector**. That path is for remote MCP URLs.

## Safety

This project only **reads** Mail data and writes `.eml` files to folders you choose. It never deletes messages from Apple Mail. Treat export folders as private mail. IMAP/Gmail drafts created in Mail may upload to the server — “never sends” is not “never leaves this Mac.”

## Layout

| Path | Purpose |
|------|---------|
| [`apps/MailExporter/`](apps/MailExporter/) | Native Mac app (single Export pane) |
| [`engine/`](engine/) | Python export engine (criteria matching, `.emlx` + attachments) |
| [`mailexporter_mcp/`](mailexporter_mcp/) | Local MCP server for Cursor / Claude / Cowork |
| [`skills/mail-exporter/`](skills/mail-exporter/) | Cursor/Claude skill (howto, never-send) |
