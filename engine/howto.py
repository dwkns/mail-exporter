"""Write `how_to_use.md` into project folders for AI assistants.

This module is the only howto generator. The bundled Resources template is the
same text with ``{{MAILBOX_NAME}}`` / ``{{OUTPUT_DIR}}`` / ``{{PROJECT_DIR}}``
placeholders.
"""

from __future__ import annotations

from pathlib import Path

from engine.project import (
    EMAIL_DIR,
    HOWTO_FILENAME,
    LEGACY_HOWTO,
    ensure_project_layout,
    infer_project_root,
    remove_legacy_howto,
)

HOW_TO_FILENAME = HOWTO_FILENAME
DRAFTS_SUBDIR = "Drafts"
SENT_SUBDIR = "Sent"


def ensure_layout(output_dir: Path) -> Path:
    """Create Email/Drafts/Sent (and the rest of the project if this is Email/)."""
    output_dir = Path(output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / DRAFTS_SUBDIR).mkdir(exist_ok=True)
    (output_dir / SENT_SUBDIR).mkdir(exist_ok=True)
    if output_dir.name == EMAIL_DIR:
        ensure_project_layout(output_dir.parent)
    return output_dir


def howto_path_for_output(output_dir: Path) -> Path:
    output_dir = Path(output_dir).expanduser()
    if output_dir.name == EMAIL_DIR:
        return output_dir.parent / HOW_TO_FILENAME
    return output_dir / HOW_TO_FILENAME


def how_to_markdown(
    *,
    mailbox_name: str = "",
    output_dir: str = "",
    project_dir: str = "",
) -> str:
    name = (mailbox_name or "this project").strip() or "this project"
    email = (output_dir or "this folder").strip() or "this folder"
    project = (project_dir or "").strip()
    if not project:
        inferred = infer_project_root(Path(email)) if email not in ("", "this folder") else None
        project = str(inferred) if inferred else email
    drafts = f"{email}/{DRAFTS_SUBDIR}"
    sent = f"{email}/{SENT_SUBDIR}"
    return f"""# {name}

This file is for an AI assistant helping the owner with a long-running email case (complaint, claim, admin, project). MailExporter rewrites it when the app guide changes. Re-read `how_to_use.md` after an update.

## First read (when the owner says “read this folder”)

You have just been pointed at this project. Do this, in order, before proposing work:

1. Read **this file** and **`STATUS.md`**.
2. Skim `Email/` with MCP `list_messages` (or the `.eml` filenames). Prefer the latest message in each thread.
3. `read_message` on the important ones. Pull **Message-ID**, who is talking, what was asked, what was promised, what is still open.
4. Glance at `Documents/` and `Notes/` if they have files.
5. Then **ask the owner** either:
   - **(a) more background** — people, account numbers, what happened offline, papers that are not in this folder yet; or
   - **(b) what to do next** — if the mail already makes the next step obvious.

Do not draft a reply on the first read unless they already said what they want sent. Do not invent facts. Update `STATUS.md` once you understand the case.

## Layout

Project: `{project}`  
Mail export: `{email}`  
Export job: **{name}**

```
{project}/
  how_to_use.md           this guide
  STATUS.md               where we are (you keep this current)
  Email/                  MailExporter output (do not dump other files here)
    *.eml
    .exported-ids.json
    Attachments/<id>/     files extracted from those emails
    Drafts/               outgoing Markdown, not yet known sent
    Sent/                 that Markdown after a matching sent `.eml`
  Documents/              papers the owner keeps (policy, invoice, letter)
  Notes/                  timeline, call log, analysis
  _archive/               superseded packs
```

`.eml` names: `YYYY-MM-DD_HHMMSS_<subject>_<short-id>.eml` (sorted by name ≈ date).

MailExporter copies matching Apple Mail messages here. It never deletes Mail.

## Markdown drafts

Write outgoing `.md` in **`Drafts/`**, not `Email/` root.

| Folder | When |
|--------|------|
| `{drafts}` | Composing, waiting for the owner to send, or not sure it went out |
| `{sent}` | After a matching sent `.eml` is in the export |

Filename: `NNN_who_subject.md`

- **`NNN`** — next number after the highest in **both** `Drafts/` and `Sent/`.
- **`who`** — name or local-part of the first To. Lowercase, hyphens, no `@`.
- **`subject`** — strip `Re:` / `Fwd:`. Lowercase, hyphens.

Keep the same filename when moving `Drafts/` → `Sent/`. MailExporter never sends; after the owner sends, the next export (job must include Sent) can move the file. If unsure, leave it in `Drafts/`. IMAP/Gmail may upload Mail drafts — “never sends” is not “never leaves this Mac.”

## Writing a reply (Markdown → Mail draft)

```markdown
---
To: someone@example.com
Cc: other@example.com
From: you@example.com
Subject: Re: Their subject here
In-Reply-To: <the-message-id-from-read_message>
Reply: reply
Attach: Documents/optional.pdf, Documents/other.pdf
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
| `In-Reply-To` | `messageId` from `read_message` (keep angle brackets). Opens a real reply if Mail has that message. |
| `Reply` | `reply` (default when In-Reply-To is set), `reply-all`, or `new`. |
| `Attach` | One or more files **inside this project**, comma+space separated (`Documents/a.pdf, Documents/b.pdf`). Prefer `Documents/…` from the project root, or a file next to the `.md` in `Drafts/`. `Email/Attachments/<id>/…` is fine. Absolute paths are allowed only under `{project}`. Paths outside the project, `~/…` to elsewhere, and `..` that escapes the project are refused. After the draft opens, MailExporter counts attachments against this list and will not return a silent OK if they differ. |
| `Format: plain` | Skip Markdown rendering. |

When the owner says “send it”, ask MailExporter to open an Apple Mail draft (never send). Use MCP `compose_draft` with the Markdown path. Do not start the mail program yourself. You can also drop the `.md` on MailExporter.

Dropping a PDF on the Export pane does **not** attach it — put it on `Attach:`. Import new papers into `Documents/` first (do not copy them into `Email/`).

| Situation | What happens |
|-----------|----------------|
| `In-Reply-To` + `Attach:` | AppleScript reply, then GUI Attach Files (quote preserved) |
| `In-Reply-To` set, no attach | Threaded reply if Mail finds the message |
| `In-Reply-To` set but not found | New draft |
| No `In-Reply-To`, or `Reply: new` | New outgoing draft |

MailExporter needs **Accessibility** (formatted paste) and **Automation → Mail**. Without Accessibility, drafts still open as plain text.

## MailExporter MCP

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
| `read_message` | Headers + body + **messageId**. |
| `list_drafts` | Inventory `Drafts/` and `Sent/` Markdown. |
| `create_job` / `edit_job` | Set up or change an export (never-send). |
| `compose_draft` | Open Mail draft/reply from Markdown in `Drafts/`. |
| `check_matches` / `export_job` | Refresh from Apple Mail. Pass `job_name` only; omit `job_id` / `force_full` unless needed. |

Typical flow after the first read: `export_job` if mail looks stale → `list_messages` / `read_message` → write `{drafts}/NNN_who_subject.md` → `compose_draft` when they say send it → `export_job` again after they send.

## Ground rules

- Do not invent email content; quote or paraphrase only what you read.
- Treat messages as private; do not exfiltrate beyond the admin task.
- Stay in **this project folder**. Import outside papers into `Documents/` rather than attaching from Downloads.
- Never send mail automatically — only open drafts.
- Keep unsent Markdown in `Drafts/`. Update `STATUS.md` when the picture changes.
"""


def how_to_template() -> str:
    """Placeholder form copied into ``apps/MailExporter/Resources/how_to_use.md``."""
    return how_to_markdown(
        mailbox_name="{{MAILBOX_NAME}}",
        output_dir="{{OUTPUT_DIR}}",
        project_dir="{{PROJECT_DIR}}",
    )


def write_how_to(output_dir: Path, *, mailbox_name: str = "") -> Path:
    """Create/update `how_to_use.md` at the project root. Returns the path written."""
    output_dir = ensure_layout(output_dir)
    project = infer_project_root(output_dir)
    if output_dir.name == EMAIL_DIR:
        ensure_project_layout(project, mailbox_name=mailbox_name)
    path = howto_path_for_output(output_dir)
    body = how_to_markdown(
        mailbox_name=mailbox_name,
        output_dir=str(output_dir),
        project_dir=str(project),
    )
    try:
        if path.is_file() and path.read_text(encoding="utf-8") == body:
            remove_legacy_howto(output_dir)
            remove_legacy_howto(project)
            return path
    except OSError:
        pass
    path.write_text(body, encoding="utf-8")
    remove_legacy_howto(output_dir)
    remove_legacy_howto(project)
    return path


def sync_how_to_all(jobs: list) -> list[Path]:
    """Rewrite `how_to_use.md` for every job whose Email folder exists on disk."""
    written: list[Path] = []
    for job in jobs:
        raw = str(getattr(job, "output_dir", "") or "").strip()
        name = str(getattr(job, "name", "") or "")
        if not raw:
            continue
        folder = Path(raw).expanduser()
        if not folder.is_dir():
            continue
        written.append(write_how_to(folder, mailbox_name=name))
    return written
