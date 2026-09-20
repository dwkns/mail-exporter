# {{MAILBOX_NAME}}

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

Project: `{{PROJECT_DIR}}`  
Mail export: `{{OUTPUT_DIR}}`  
Export job: **{{MAILBOX_NAME}}**

```
{{PROJECT_DIR}}/
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
| `{{OUTPUT_DIR}}/Drafts` | Composing, waiting for the owner to send, or not sure it went out |
| `{{OUTPUT_DIR}}/Sent` | After a matching sent `.eml` is in the export |

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
Attach: Documents/optional.pdf
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
| `Attach` | File **inside this project**. Prefer `Documents/…` or `Email/Attachments/<id>/…`. Absolute paths are fine if they stay under `{{PROJECT_DIR}}`. Paths outside the project, `~/…` to elsewhere, and `..` that escapes the project are refused. |
| `Format: plain` | Skip Markdown rendering. |

When the owner says “send it”, open an Apple Mail draft (never send):

```bash
/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine append-draft "{{OUTPUT_DIR}}/Drafts/NNN_who_subject.md"
```

Same command as `draft`. Dev: `python3 -m engine append-draft path.md`. Or drop the `.md` on MailExporter, or MCP `compose_draft`.

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
{
  "mcpServers": {
    "mail-exporter": {
      "command": "/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine",
      "args": ["mcp"]
    }
  }
}
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

Typical flow after the first read: `export_job` if mail looks stale → `list_messages` / `read_message` → write `{{OUTPUT_DIR}}/Drafts/NNN_who_subject.md` → `append-draft` when they say send it → `export_job` again after they send.

## Ground rules

- Do not invent email content; quote or paraphrase only what you read.
- Treat messages as private; do not exfiltrate beyond the admin task.
- Stay in **this project folder**. Import outside papers into `Documents/` rather than attaching from Downloads.
- Never send mail automatically — only open drafts.
- Keep unsent Markdown in `Drafts/`. Update `STATUS.md` when the picture changes.
