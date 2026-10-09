---
name: mail-exporter
description: Export Apple Mail with MailExporter jobs, read .eml context, write Drafts Markdown, and open Apple Mail drafts. Never send mail. Never invent email content. Never delete Mail.
---

# MailExporter

Criteria jobs copy matching Apple Mail messages to a folder of `.eml` files. Assistants read that folder, write Markdown in `Drafts/`, and open an Apple Mail **draft**. The owner sends. MailExporter never sends and never deletes Mail.

## Ask the app

Cursor and Claude do not open Apple Mail’s private folder. They do not start the mail program.

Use the MCP tools. MailExporter.app copies the mail, opens the draft, and saves the job.

**Create a reply** (or “write a reply”, or “draft a reply”) means write the Markdown file only. Do not create anything in Mail.

**Create a draft** (or “open a draft”, or “send it”) means create the draft in Mail. Never send.

Write `Drafts/NNN_who_subject.md`. Call `compose_draft` only for a draft.

## MCP

Local stdio only. Installed helper: `MailExporterEngine mcp`. Tools: `list_jobs`, `list_messages` (From/Subject/Date/Message-ID), `read_message`, `list_drafts`, `create_job`, `edit_job`, `compose_draft`, `check_matches`, `export_job`, `clear_target`, `write_howto`.

`export_job` / `check_matches` take `job_name` (or `job_id`). `force_full` is optional and may be omitted. Do not pass an `engine` argument.

One bad job does not stop the others. `list_jobs` still lists every job. A job whose saved condition has no value includes an `error` field. That text names the job name, the job id, the config file, and the condition (`match.groups[0].conditions[0]: values must be a non-empty array`). `list_messages`, `list_drafts`, and `read_message` still read that folder. `check_matches` and `export_job` on that job return the error and do not export. `create_job` and `edit_job` refuse an empty condition row.

`read_message` / `clear_target` are sandboxed to configured export folders. `Attach:` paths must stay inside the **project folder**. Prefer `Documents/…` from the project root; a file next to the `.md` in `Drafts/` also works. List several with comma+space. After the draft opens, `compose_draft` reports attached vs requested and fails if they differ. Do not put a job folder inside Apple Mail’s private folder.

## First read

When the owner points you at a project folder (“read this folder”):

1. Read `how_to_use.md` and `STATUS.md`.
2. Skim `Email/` (`list_messages` / `.eml` names). `read_message` the important ones.
3. Glance at `Documents/` and `Notes/`.
4. Ask either **(a) more background** or **(b) what to do next**. Do not draft a reply on the first read unless they already said what to send.

## Project folder

```
<project>/
  how_to_use.md
  STATUS.md
  Email/
    *.eml
    .exported-ids.json
    Attachments/<id>/
    Drafts/
    Sent/
  Documents/
  Notes/
  _archive/
```

`write_howto` with no job rewrites `how_to_use.md` in every project. MailExporter also does this on launch when the bundled guide changed.

After the owner sends, the next export can move matching Markdown from `Drafts/` to `Sent/` (job must include Sent). IMAP/Gmail drafts Mail creates may upload — “never sends” is not “never leaves this Mac.”

## Permissions

Full Disk Access is only for MailExporter. Cursor and Claude do not need it. Automation → Mail is for drafts. MailExporter creates the draft in the background. Upload uses IMAP when the account is iCloud, the keychain item `MailExporter iCloud IMAP` exists, and TLS succeeds within 3 seconds. Otherwise it imports a mailbox and moves the message into Drafts. Accessibility is not required for drafts.
