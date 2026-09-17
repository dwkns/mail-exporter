"""Write `_how_to_use.md` into export folders for AI assistants.

This module is the only howto generator. The bundled Resources template is the
same text with ``{{MAILBOX_NAME}}`` / ``{{OUTPUT_DIR}}`` placeholders.
"""

from __future__ import annotations

from pathlib import Path

HOW_TO_FILENAME = "_how_to_use.md"
DRAFTS_SUBDIR = "Drafts"
SENT_SUBDIR = "Sent"


def ensure_layout(output_dir: Path) -> Path:
    """Create the export folder plus Drafts/ and Sent/ for Markdown drafts."""
    output_dir = Path(output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / DRAFTS_SUBDIR).mkdir(exist_ok=True)
    (output_dir / SENT_SUBDIR).mkdir(exist_ok=True)
    return output_dir


def how_to_markdown(*, mailbox_name: str = "", output_dir: str = "") -> str:
    name = (mailbox_name or "this export").strip() or "this export"
    folder = (output_dir or "this folder").strip() or "this folder"
    drafts = f"{folder}/{DRAFTS_SUBDIR}"
    sent = f"{folder}/{SENT_SUBDIR}"
    return f"""# MailExporter — how to use this folder

This file is for an AI assistant helping with admin on behalf of the mailbox owner.

## What this folder contains

Path: `{folder}`  
Export: **{name}**

MailExporter creates this layout (leave `_how_to_use.md` in place):

```
{folder}/
  *.eml                 exported Apple Mail messages (RFC 822 / MIME)
  .exported-ids.json    Message-IDs already exported (do not delete unless a full re-export)
  _how_to_use.md        this guide
  Attachments/<id>/     files extracted next to the `.eml` so you can @ a PDF
  Drafts/               Markdown you write — not yet known to have been sent
  Sent/                 those Markdown files after a matching sent `.eml` appears
```

### `.eml` filenames

`YYYY-MM-DD_HHMMSS_<subject>_<short-id>.eml`

Sorted by name ≈ chronological order of the message date.

### What is *not* here

- The live Apple Mail database (MailExporter copies matching messages out).
- MailExporter never deletes messages from Apple Mail.

## Why you are here

Read these emails to understand what has been **sent and received** so you have context on the current discussion before you act (summarize, draft replies, chase invoices, update records, etc.). Prefer recent threads and the latest message in each conversation first.

## How to read a message

1. Use MCP `list_messages` / `read_message`, or open the `.eml` as text.
2. Note headers: `From`, `To`, `Cc`, `Subject`, `Date`, **`Message-ID`**.
3. Read the body for substance; ignore quoted noise when a later reply supersedes it.

## Markdown drafts — where they go

Write every outgoing `.md` into **`Drafts/`**, not the export root (that folder is for `.eml` files).

| Folder | When |
|--------|------|
| `{drafts}` | While composing, waiting for the owner to send, or you are not sure it went out |
| `{sent}` | After you can see the sent copy in the exported `.eml` files |

MailExporter creates `Drafts/` and `Sent/` next to the `.eml` files. Do not invent other locations.

### Filenames

`NNN_who_subject.md`

- **`NNN`** — three-digit sequence (`001`, `002`, …). Use the next number after the highest already used in **both** `Drafts/` and `Sent/` so numbers never collide.
- **`who`** — who it is to: the person’s name, or the local-part of the first `To:` address. Lowercase, hyphens, no `@`.
- **`subject`** — enough of the subject to recognise the mail. Strip leading `Re:` / `Fwd:` / `Fw:`. Lowercase, hyphens, filesystem-safe.

Examples:

- `001_dhl-claims_returned-goods-relief.md`
- `014_jane-bloggs_chimney-survey-quote.md`

Keep the **same filename** when moving a file from `Drafts/` to `Sent/`.

### After it has been sent

MailExporter **never sends**. After the owner sends from Mail, the next export looks for a matching sent `.eml` (the job must include Sent) and **moves** the Markdown from `Drafts/` to `Sent/`. You can still do that by hand if the match is unclear.

If you cannot be sure it was sent, leave it in `Drafts/`.

IMAP and Gmail accounts upload drafts Mail creates. “Never sends” is not “never leaves this Mac.”

## Writing a reply (Markdown → Mail draft)

Produce a Markdown file in `Drafts/` with fenced front matter, then the body. **Always include a Subject.** Never hard-wrap paragraphs.

```markdown
---
To: someone@example.com
Cc: other@example.com
From: you@example.com
Subject: Re: Their subject here
In-Reply-To: <the-message-id-from-read_message>
Reply: reply
Attach: optional.pdf
---

Hello,

Thanks for the **update**. Two points:

- First item
- Second item

Best regards
```

| Key | Notes |
|-----|--------|
| `To` / `Cc` / `Bcc` | Comma-separated. `Name <addr>` is fine. On threaded replies these **override** Mail’s default recipients. |
| `Subject` | **Required** for rich formatting in Mail. |
| `In-Reply-To` | Message-ID of the mail you are answering (from `read_message` → `messageId`). When set, MailExporter opens a **real reply** if it can find that message in Mail; otherwise a new draft. |
| `Reply` | `reply` (default when In-Reply-To is set), `reply-all`, or `new` (force a non-threaded draft). |
| `Attach` | Paths relative to the `.md` file’s folder. No `..`, `~/…`, or absolute paths. |
| `Format: plain` | Skip Markdown rendering. |

### How to open the draft (when the owner says “send it”)

MailExporter **never sends**. “Send it”, “put it in Mail”, or “open a draft” means: create an **Apple Mail draft** from the `.md` and leave sending to the owner.

**Exact command** (installed app helper — works from Cursor / Claude with no GUI drop zone):

```bash
/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine append-draft "{drafts}/NNN_who_subject.md"
```

Use an absolute path to the Markdown file. Same command as `draft` instead of `append-draft`. Dev checkout: `python3 -m engine append-draft path.md`.

Other ways (same result, still never send):

1. **MailExporter** — drop the `.md` on the Export pane (or Choose Files).
2. **MCP** — `compose_draft` with `path` to the `.md` (or inline `markdown`, which is written into `Drafts/` first).

Drafts open via **AppleScript** (native Mail reply quote; **GUI Attach Files** for reply + attachments).

### Attachments

Use `Attach:` (also `Attachment:` / `Attachments:`) with paths **relative to the `.md` file’s folder**. `..`, `~/…`, and absolute paths are refused. Dropping a PDF/image onto the Export drop zone does **not** attach it — put it on an `Attach:` line. Reply + Attach uses Mail’s **Attach Files…** menu so the quoted original stays intact.

### Replies vs new drafts

| Situation | What happens |
|-----------|----------------|
| `In-Reply-To` + `Attach:` | AppleScript reply, then GUI Attach Files (quote preserved) |
| `In-Reply-To` set, no attach | AppleScript **threaded reply** if Mail finds the message |
| `In-Reply-To` set but not found | New draft |
| No `In-Reply-To`, or `Reply: new` | New outgoing draft |

Copy `messageId` from `read_message` into `In-Reply-To` exactly (angle brackets included).

### Permissions (once)

MailExporter needs **Accessibility** (formatted paste) and **Automation → Mail** (create drafts/replies). Without Accessibility, drafts still open as plain text.

## MailExporter MCP

Quickest (installed app, no Python):

```json
{{
  "mcpServers": {{
    "mail-exporter": {{
      "command": "/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine",
      "args": ["mcp"]
    }}
  }}
}}
```

Or Settings → Advanced → Install mail-exporter MCP.

| Tool | Use when |
|------|----------|
| `list_jobs` | See exports and their folders. |
| `list_messages` | List `.eml` files with From / Subject / Date / Message-ID. |
| `read_message` | Headers + body + **messageId** (copy into `In-Reply-To`). |
| `list_drafts` | Inventory `Drafts/` and `Sent/` Markdown. |
| `create_job` / `edit_job` | Set up or change an export (never-send). |
| `compose_draft` | Open Mail draft/reply from Markdown in `Drafts/`. |
| `check_matches` / `export_job` | Refresh export from Apple Mail (then look for sent copies). |

Typical admin flow:

1. `export_job` if mail looks stale.
2. `list_messages` → `read_message` for context; keep the `messageId`.
3. Write `{drafts}/NNN_who_subject.md` with `In-Reply-To: <messageId>`.
4. Open a Mail draft (never send): `/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine append-draft {drafts}/NNN_who_subject.md`
5. After the owner sends: `export_job` again. Matching Markdown moves to `{sent}`.

## Ground rules

- Do not invent email content; quote or paraphrase only what you read.
- Treat messages as private; do not exfiltrate beyond the admin task.
- Prefer MCP or files in **this** folder over searching the whole disk.
- Never send mail automatically — only open drafts.
- Keep unsent Markdown in `Drafts/`; MailExporter moves it to `Sent/` when an exported `.eml` shows it went out.
"""


def how_to_template() -> str:
    """Placeholder form copied into ``apps/MailExporter/Resources/_how_to_use.md``."""
    return how_to_markdown(
        mailbox_name="{{MAILBOX_NAME}}",
        output_dir="{{OUTPUT_DIR}}",
    )


def write_how_to(output_dir: Path, *, mailbox_name: str = "") -> Path:
    """Create/update `_how_to_use.md` in the export folder. Returns the path written."""
    output_dir = ensure_layout(output_dir)
    path = output_dir / HOW_TO_FILENAME
    path.write_text(
        how_to_markdown(mailbox_name=mailbox_name, output_dir=str(output_dir)),
        encoding="utf-8",
    )
    return path
