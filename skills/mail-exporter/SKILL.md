---
name: mail-exporter
description: Export Apple Mail with MailExporter jobs, read .eml context, write Drafts Markdown, and open Apple Mail drafts. Never send mail. Never invent email content. Never delete Mail.
---

# MailExporter

Criteria jobs copy matching Apple Mail messages to a folder of `.eml` files. Assistants read that folder, write Markdown in `Drafts/`, and open an Apple Mail **draft**. The owner sends. MailExporter never sends and never deletes Mail.

## Installed helper (prefer this)

```bash
/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine
```

Subcommands: `list`, `export`, `export --json`, `append-draft` (alias `draft`), `mcp`.

When the owner says **send it**, write `Drafts/NNN_who_subject.md` (do not invent content) and run:

```bash
/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine append-draft /absolute/path/to/Drafts/NNN_who_subject.md
```

That opens a draft. It never sends.

## MCP

Local stdio only. Installed helper: `MailExporterEngine mcp`. Tools: `list_jobs`, `list_messages` (From/Subject/Date/Message-ID), `read_message`, `list_drafts`, `create_job`, `edit_job`, `compose_draft`, `check_matches`, `export_job`, `clear_target`, `write_howto`.

`export_job` / `check_matches` take `job_name` (or `job_id`). `force_full` is optional and may be omitted. Do not pass an `engine` argument.

`read_message` / `clear_target` are sandboxed to configured export folders. `Attach:` paths must be relative to the `.md` (no `..`, `~/`, or absolute).

## Export folder

```
<outputDir>/
  *.eml
  .exported-ids.json
  _how_to_use.md
  Attachments/<id>/
  Drafts/
  Sent/
```

`write_howto` with no job rewrites `_how_to_use.md` in every export folder. MailExporter also does this on launch when the bundled guide changed, so “re-read the instructions” picks up the latest copy.

After the owner sends, the next export can move matching Markdown from `Drafts/` to `Sent/` (job must include Sent). IMAP/Gmail drafts Mail creates may upload — “never sends” is not “never leaves this Mac.”

## Permissions

Full Disk Access for whoever scans Mail (MailExporter, Cursor, Claude, or Terminal). Accessibility for rich paste. Automation → Mail for drafts.
