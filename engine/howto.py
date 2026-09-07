"""Write `_how_to_use.md` into export folders for AI assistants."""

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
    name = (mailbox_name or "this mailbox").strip() or "this mailbox"
    folder = (output_dir or "this folder").strip() or "this folder"
    drafts = f"{folder}/{DRAFTS_SUBDIR}"
    sent = f"{folder}/{SENT_SUBDIR}"
    return f"""# MailExporter — how to use this folder

This file is for an AI assistant helping with admin on behalf of the mailbox owner.

## What this folder contains

Path: `{folder}`  
Smart mailbox: **{name}**

MailExporter creates this layout (leave `_how_to_use.md` in place):

```
{folder}/
  *.eml                 exported Apple Mail messages (RFC 822 / MIME)
  .exported-ids.json    Message-IDs already exported (do not delete unless a full re-export)
  _how_to_use.md        this guide
  Drafts/               Markdown you write — not yet known to have been sent
  Sent/                 those Markdown files after you know Mail sent them
```

### `.eml` filenames

`YYYY-MM-DD_HHMMSS_<subject>_<short-id>.eml`

Sorted by name ≈ chronological order of the message date.

### What is *not* here

- The live Apple Mail database (MailExporter copies matching messages out).
- Attachments may be inlined in the `.eml` when MailExporter reassembled them; treat the file as the full message.

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

Keep the **same filename** when you move a file from `Drafts/` to `Sent/`.

### After it has been sent

MailExporter never sends mail. After the owner sends from Mail:

1. Run `export_job` (or wait for the next export) so the sent copy appears as a new `.eml`. This needs **Include messages from Sent** on the job.
2. Match that `.eml` to a file in `Drafts/` using Subject (ignore `Re:` / `Fwd:`), `To`, and `In-Reply-To` / thread.
3. **Move** (do not copy or delete) the `.md` from `Drafts/` to `Sent/`.

If you cannot be sure it was sent, leave it in `Drafts/`.

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
| `Attach` | Paths relative to the `.md` file’s folder. `../…` is allowed; `~/…` and absolute paths are not. |
| `Format: plain` | Skip Markdown rendering. |

### How to open the draft

1. **MailExporter → Send Messages** — drop the `.md` file(s) on the drop target (or Choose Files…).
2. **MCP** — `compose_draft` with `path` to the `.md` (or inline `markdown`).
3. **CLI** — `python -m engine append-draft path.md`

Neither path sends mail. Drafts open via **AppleScript** (native Mail reply quote; **GUI Attach Files** for reply + attachments).

### Attachments

Use `Attach:` (also `Attachment:` / `Attachments:`) with paths **relative to the `.md` file’s folder** (`../…` may reach sibling folders). Dropping a PDF/image onto Send Messages does **not** attach it — put it on an `Attach:` line. Reply + Attach uses Mail’s **Attach Files…** menu so the quoted original stays intact.

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

```json
{{
  "mcpServers": {{
    "mail-exporter": {{
      "command": "/path/to/mail-exporter/.venv/bin/python",
      "args": ["-m", "mailexporter_mcp"],
      "cwd": "/path/to/mail-exporter",
      "env": {{
        "PYTHONPATH": "/path/to/mail-exporter"
      }}
    }}
  }}
}}
```

| Tool | Use when |
|------|----------|
| `list_jobs` | See smart mailboxes and export folders. |
| `list_messages` | List `.eml` files for a job. |
| `read_message` | Headers + body + **messageId** (copy into `In-Reply-To`). |
| `compose_draft` | Open Mail draft/reply from Markdown in `Drafts/`. |
| `check_matches` / `export_job` | Refresh export from Apple Mail (then look for sent copies). |

Typical admin flow:

1. `export_job` if mail looks stale.
2. `list_messages` → `read_message` for context; keep the `messageId`.
3. Write `{drafts}/NNN_who_subject.md` with `In-Reply-To: <messageId>`.
4. `compose_draft` (or drop onto Send Messages).
5. After the owner sends: `export_job` again, match the new `.eml`, move the `.md` to `{sent}`.

## Ground rules

- Do not invent email content; quote or paraphrase only what you read.
- Treat messages as private; do not exfiltrate beyond the admin task.
- Prefer MCP or files in **this** folder over searching the whole disk.
- Never send mail automatically — only open drafts.
- Keep unsent Markdown in `Drafts/`; move to `Sent/` only when an exported `.eml` shows it went out.
"""


def write_how_to(output_dir: Path, *, mailbox_name: str = "") -> Path:
    """Create/update `_how_to_use.md` in the export folder. Returns the path written."""
    output_dir = ensure_layout(output_dir)
    path = output_dir / HOW_TO_FILENAME
    path.write_text(
        how_to_markdown(mailbox_name=mailbox_name, output_dir=str(output_dir)),
        encoding="utf-8",
    )
    return path
