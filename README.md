# MailExporter

Criteria-based export of Apple Mail messages to `.eml` files — without relying on smart folders.

Define jobs (a mailbox name, match rules, and an output folder). MailExporter scans `~/Library/Mail`, copies matching messages, and keeps an incremental export so later runs only pick up new mail. It never deletes messages from Apple Mail.

An MCP server (`mail-exporter`) lets Cursor, Claude Desktop, and Claude Cowork list jobs, refresh exports, and read messages.

## Requirements

- macOS (reads Apple Mail’s on-disk store)
- **Full Disk Access** for whichever app actually scans Mail (see [Permissions](#permissions))
- Python 3.10+ for the CLI and MCP server
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

Quit and reopen the app after toggling access.

## Mac app

```bash
apps/MailExporter/build.sh
open apps/MailExporter/MailExporter.app
```

The build produces a self-contained app: Swift UI plus a bundled `MailExporterEngine` (no Homebrew Python or `rg` at runtime).

- **Config** — add jobs, set the output folder, add match clauses (From / To / Subject / Body / Date), preview match count
- **Run** — export one job or all; one-line result plus a notification

Jobs are stored at:

```text
~/Library/Application Support/MailExporter/jobs.json
```

Each export folder looks like this (MailExporter creates `Drafts/` and `Sent/`):

```text
<outputDir>/
  *.eml                 exported messages
  .exported-ids.json    incremental state — do not delete unless a full re-export
  _how_to_use.md        notes for an AI assistant
  Drafts/               Markdown the AI writes before the mail is known to be sent
  Sent/                 those Markdown files after a sent copy appears in the export
```

## Engine CLI

From the repository root:

```bash
python3 -m engine seed          # example jobs (edit From addresses before a real export)
python3 -m engine list
python3 -m engine export --dry-run --job-name DHL
python3 -m engine export --job-name DHL
```

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

### Install the Python package

From the repository root (once):

### Quickest setup (using the installed Mac app — zero Python install needed)

If `MailExporter.app` is installed in `/Applications`, you can run the MCP server directly from the app bundle without Python or virtual environments:

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

### Development setup (from source venv)

If developing from source:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-mcp.txt
```

Confirm it starts (it will wait on stdin; Ctrl-C to quit):

```bash
PYTHONPATH="$(pwd)" .venv/bin/python -m mailexporter_mcp
```

### Tools

| Tool | Use when |
|------|----------|
| `list_jobs` | See jobs (smart mailboxes) and their export folders |
| `list_messages` | List `.eml` files for a job (by name or id) |
| `read_message` | Read headers + body of one `.eml` |
| `compose_draft` | Open a Mail draft from Markdown (AppleScript) |
| `check_matches` | Dry-run: how many Mail messages currently match |
| `export_job` | Refresh the folder from Apple Mail (incremental unless `force_full`) |
| `clear_target` | Delete exported `.eml` files (debug / full redo) |
| `write_howto` | Refresh `_how_to_use.md` in the export folder |

Typical flow: `list_jobs` → `list_messages` / `read_message` → write a numbered `.md` in `Drafts/` → `compose_draft` → `export_job` later and move the `.md` to `Sent/` once a matching sent copy is in the export.

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

Project config (this repo already has `.cursor/mcp.json`) or a global config at `~/.cursor/mcp.json`.

**Cursor Settings → MCP** (or **Customize → MCP**), then add a server, **or** write:

```json
{
  "mcpServers": {
    "mail-exporter": {
      "command": "/path/to/mail-exporter/.venv/bin/python",
      "args": ["-m", "mailexporter_mcp"],
      "cwd": "/path/to/mail-exporter",
      "env": {
        "PYTHONPATH": "/path/to/mail-exporter"
      }
    }
  }
}
```

In a project file you can use Cursor interpolation instead of a hard-coded path:

```json
{
  "mcpServers": {
    "mail-exporter": {
      "command": "${workspaceFolder}/.venv/bin/python",
      "args": ["-m", "mailexporter_mcp"],
      "cwd": "${workspaceFolder}",
      "env": {
        "PYTHONPATH": "${workspaceFolder}"
      }
    }
  }
}
```

Reload the window (**Developer: Reload Window**) or restart Cursor. In **Settings → MCP**, `mail-exporter` should show as connected.

Grant **Cursor** Full Disk Access if `export_job` / `check_matches` cannot read Mail.

Ask Agent things like: “List MailExporter jobs” or “Read the latest messages in the DHL export.”

---

### Claude Desktop

1. Install [Claude Desktop](https://claude.ai/download) and complete the venv setup above.
2. Open **Claude → Settings → Developer → Edit Config**. That creates or opens:

   `~/Library/Application Support/Claude/claude_desktop_config.json`

3. Merge this into the existing `mcpServers` object (keep any servers you already have):

```json
{
  "mcpServers": {
    "mail-exporter": {
      "command": "/path/to/mail-exporter/.venv/bin/python",
      "args": ["-m", "mailexporter_mcp"],
      "env": {
        "PYTHONPATH": "/path/to/mail-exporter"
      }
    }
  }
}
```

4. Fully quit Claude Desktop (Cmd-Q) and reopen it.
5. Check **Settings → Developer** for a connected `mail-exporter`, or click **+** in a chat → **Connectors**.
6. Grant **Claude** Full Disk Access if exports cannot read Mail.

Claude Desktop only understands local stdio servers in that JSON file. Use absolute paths; `python3` on PATH often fails because the GUI app does not inherit your shell profile.

---

### Claude Cowork

MailExporter must stay on your Mac (it reads `~/Library/Mail`). Cowork can use it as a **local connector**, not as a cloud/remote custom connector.

1. Install the server in **Claude Desktop** first (same `claude_desktop_config.json` as above). Cowork does not have a separate MCP config file.
2. Open the latest Claude Desktop app. In the message box, choose **Cowork**.
3. Click **+** → **Connectors** and enable **mail-exporter** for that session.
4. Keep Claude Desktop running. Local connectors (including this server) are provided by the desktop app. If you start Cowork on the web or on a phone, the desktop app on this Mac must stay open or Cowork cannot reach local MCP.
5. Grant **Claude** Full Disk Access (same as Desktop).

Do **not** add this server under **Customize → Connectors → Add custom connector**. That path is for remote MCP URLs that Anthropic’s cloud dials over the public internet. This server has no public URL and should not get one — it can list and export private mail.

Cloud Cowork sessions do not run local MCP inside Anthropic’s sandbox. They only reach this server through Claude Desktop on your machine.

## Safety

This project only **reads** Mail data and writes `.eml` files to folders you choose. It never deletes messages from Apple Mail. Treat export folders as private mail.

## Tests

```bash
python3 -m unittest tests.test_criteria -v
```

## Layout

| Path | Purpose |
|------|---------|
| [`apps/MailExporter/`](apps/MailExporter/) | Native Mac app (Config + Run) |
| [`engine/`](engine/) | Python export engine (criteria matching, `.emlx` + attachments) |
| [`mailexporter_mcp/`](mailexporter_mcp/) | Local MCP server for Cursor / Claude / Cowork |
