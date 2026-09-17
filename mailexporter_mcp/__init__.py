"""MailExporter MCP — local stdio server for AI control of exports and mail context."""

from __future__ import annotations

import email
import json
import os
import re
import subprocess
import sys
from email.header import decode_header, make_header
from email.message import Message
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

# Repo root on PYTHONPATH / cwd
_REPO = Path(__file__).resolve().parents[1]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from engine.cli import run_export  # noqa: E402
from engine.compose_draft import compose_draft as _compose_draft  # noqa: E402
from engine.compose_draft import compose_markdown_text  # noqa: E402
from engine.criteria import parse_match  # noqa: E402
from engine.howto import DRAFTS_SUBDIR, HOW_TO_FILENAME, SENT_SUBDIR, sync_how_to_all, write_how_to  # noqa: E402
from engine.jobs import Job, JobsFile, default_jobs_path, load_jobs, save_jobs  # noqa: E402

mcp = FastMCP("mail-exporter")

_EXPORT_MARKER = ".exported-ids.json"


def _config_path() -> Path:
    env = os.environ.get("MAILEXPORTER_CONFIG", "").strip()
    return Path(env).expanduser() if env else default_jobs_path()


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _job_output_dirs() -> list[Path]:
    return [
        Path(j.output_dir).expanduser().resolve()
        for j in load_jobs(_config_path()).jobs
        if j.output_dir
    ]


def _resolve_eml_path(
    *,
    path: str = "",
    job_name: str = "",
    filename: str = "",
) -> Path:
    """Resolve an .eml path that must live under a configured job outputDir."""
    if path.strip():
        eml = Path(path).expanduser().resolve()
        if eml.suffix.lower() != ".eml":
            raise ValueError("path must be a .eml file")
        allowed = _job_output_dirs()
        if not any(_is_within(eml, root) for root in allowed):
            raise ValueError(
                "path must be under a configured job outputDir "
                "(use job_name + filename, or a path inside an export folder)"
            )
        return eml

    if job_name.strip() and filename.strip():
        name = Path(filename).name
        if name != filename or "/" in filename or "\\" in filename:
            raise ValueError("filename must be a bare .eml name (no path separators)")
        if not name.lower().endswith(".eml"):
            raise ValueError("filename must end with .eml")
        job = _find_job(job_name=job_name)
        root = Path(job.output_dir).expanduser().resolve()
        eml = (root / name).resolve()
        if not _is_within(eml, root):
            raise ValueError("filename escapes the job outputDir")
        return eml

    raise ValueError("provide path, or job_name + filename")


def _assert_clearable_export_folder(folder: Path) -> None:
    """Refuse clear_target unless the folder looks like a MailExporter export dir."""
    folder = folder.expanduser().resolve()
    if not folder.is_dir():
        raise ValueError(f"folder missing: {folder}")
    marker = folder / _EXPORT_MARKER
    howto = folder / HOW_TO_FILENAME
    if not marker.is_file() and not howto.is_file():
        raise ValueError(
            f"refusing to clear {folder}: not a MailExporter export folder "
            f"(missing {_EXPORT_MARKER} or {HOW_TO_FILENAME})"
        )
    # Also require it matches a configured job outputDir
    if not any(folder == root for root in _job_output_dirs()):
        raise ValueError(
            f"refusing to clear {folder}: not a configured job outputDir"
        )


_INSTALLED_ENGINE = Path(
    "/Applications/MailExporter.app/Contents/Resources/"
    "MailExporterEngine/MailExporterEngine"
)


def _find_engine() -> tuple[list[str], Path]:
    """Return (argv_prefix, cwd) for running the engine CLI.

    Frozen MCP (``MailExporterEngine mcp``) must invoke this same binary
    *without* ``-m engine``. That pair is a CPython interpreter option; the
    bundled CLI treats ``engine`` as the subcommand and argparse fails with
    ``invalid choice: 'engine'``.
    """
    if getattr(sys, "frozen", False):
        exe = Path(sys.executable)
        return [str(exe)], exe.parent
    env = os.environ.get("MAILEXPORTER_ENGINE", "").strip()
    candidates: list[Path] = []
    if env:
        candidates.append(Path(env).expanduser())
    candidates.append(_INSTALLED_ENGINE)
    candidates.append(
        _REPO
        / "apps/MailExporter/MailExporter.app/Contents/Resources/"
        "MailExporterEngine/MailExporterEngine"
    )
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return [str(path)], path.parent
    return [sys.executable, "-m", "engine"], _REPO


def _run_engine(args: list[str]) -> dict[str, Any]:
    prefix, cwd = _find_engine()
    config = _config_path()
    # Bundled MailExporterEngine is the CLI. Never prefix args with "engine".
    cmd = prefix + ["--config", str(config), *args]
    env = os.environ.copy()
    # Prefer bundled rg when running via the app engine.
    rg = (
        _REPO
        / "apps/MailExporter/MailExporter.app/Contents/Resources/bin/rg"
    )
    if rg.is_file():
        env["MAILEXPORTER_RG"] = str(rg)
        env["PATH"] = f"{rg.parent}:{env.get('PATH', '')}"
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        env=env,
    )
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    json_line = ""
    for line in reversed(out.splitlines()):
        if line.startswith("{"):
            json_line = line
            break
    payload: dict[str, Any]
    if json_line:
        try:
            payload = json.loads(json_line)
        except json.JSONDecodeError:
            payload = {"raw": out, "ok": proc.returncode == 0}
    else:
        payload = {"raw": out or err, "ok": proc.returncode == 0}
    payload["_exit"] = proc.returncode
    if err and "error" not in payload:
        payload["_stderr"] = err
    return payload


def _call_export(
    *,
    job_name: str | None = None,
    job_id: str | None = None,
    force_full: bool | None = False,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Run export in-process so frozen MCP never shells out with ``-m engine``."""
    name = (job_name or "").strip()
    jid = (job_id or "").strip()
    if not name and not jid:
        return {"ok": False, "error": "provide job_name or job_id"}
    payload, code = run_export(
        config=str(_config_path()),
        job_id=jid or None,
        job_name=name or None,
        dry_run=dry_run,
        force_full=bool(force_full),
    )
    payload.setdefault("ok", code == 0)
    payload["_exit"] = code
    return payload


def _find_job(*, job_id: str | None = None, job_name: str | None = None):
    jobs = load_jobs(_config_path()).jobs
    if job_id:
        for j in jobs:
            if j.id == job_id:
                return j
        raise ValueError(f"job id not found: {job_id}")
    if job_name:
        needle = job_name.lower().strip()
        for j in jobs:
            if j.name.lower() == needle:
                return j
        raise ValueError(f"job name not found: {job_name}")
    raise ValueError("provide job_id or job_name")


def _decode_hdr(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def _body_text(msg: Message, limit: int = 120_000) -> str:
    texts: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            disp = str(part.get("Content-Disposition") or "")
            if "attachment" in disp.lower():
                continue
            if ctype == "text/plain":
                try:
                    texts.append(part.get_payload(decode=True).decode(
                        part.get_content_charset() or "utf-8", errors="replace"
                    ))
                except Exception:
                    continue
        if not texts:
            for part in msg.walk():
                if part.get_content_type() == "text/html":
                    try:
                        html = part.get_payload(decode=True).decode(
                            part.get_content_charset() or "utf-8", errors="replace"
                        )
                        texts.append(re.sub(r"<[^>]+>", " ", html))
                    except Exception:
                        continue
                    break
    else:
        try:
            texts.append(
                msg.get_payload(decode=True).decode(
                    msg.get_content_charset() or "utf-8", errors="replace"
                )
            )
        except Exception:
            texts.append(str(msg.get_payload()))
    body = "\n".join(texts).strip()
    if len(body) > limit:
        return body[:limit] + "\n…[truncated]"
    return body


@mcp.tool()
def list_jobs() -> str:
    """List MailExporter jobs (exports) and their folders."""
    path = _config_path()
    jobs = load_jobs(path).jobs
    rows = [
        {
            "id": j.id,
            "name": j.name,
            "outputDir": j.output_dir,
            "includeSent": j.include_sent,
            "includeBin": j.include_bin,
            "includeThread": j.include_thread,
        }
        for j in jobs
    ]
    return json.dumps({"config": str(path), "jobs": rows}, indent=2)


@mcp.tool()
def list_messages(job_name: str = "", job_id: str = "", limit: int = 100) -> str:
    """List exported .eml files for a job with From/Subject/Date/Message-ID.

    Newest filenames last. Threads are grouped by In-Reply-To / References.
    """
    job = _find_job(job_id=job_id or None, job_name=job_name or None)
    folder = Path(job.output_dir).expanduser()
    if not folder.is_dir():
        return json.dumps({"error": f"folder missing: {folder}", "job": job.name})
    files = sorted(folder.glob("*.eml"), key=lambda p: p.name)
    total = len(files)
    if limit > 0:
        files = files[-limit:]
    messages: list[dict[str, Any]] = []
    by_id: dict[str, str] = {}
    for path in files:
        try:
            raw = path.read_bytes()
            msg = email.message_from_bytes(raw)
        except Exception:
            messages.append({"filename": path.name, "path": str(path), "error": "unreadable"})
            continue
        mid = (msg.get("Message-ID") or msg.get("Message-Id") or "").strip()
        in_reply = (msg.get("In-Reply-To") or "").strip()
        refs = (msg.get("References") or "").strip()
        row = {
            "filename": path.name,
            "path": str(path),
            "from": _decode_hdr(msg.get("From")),
            "subject": _decode_hdr(msg.get("Subject")),
            "date": msg.get("Date") or "",
            "messageId": mid,
            "inReplyTo": in_reply,
            "references": refs,
        }
        messages.append(row)
        if mid:
            by_id[mid.strip().lower()] = path.name

    threads: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in messages:
        key = row.get("filename") or ""
        if key in seen:
            continue
        root = (row.get("inReplyTo") or "").strip().lower()
        group = [row]
        seen.add(key)
        if root:
            for other in messages:
                oname = other.get("filename") or ""
                if oname in seen:
                    continue
                omid = (other.get("messageId") or "").strip().lower()
                oin = (other.get("inReplyTo") or "").strip().lower()
                oref = (other.get("references") or "").lower()
                if omid == root or oin == root or (root and root in oref):
                    group.append(other)
                    seen.add(oname)
        threads.append(
            {
                "root": row.get("inReplyTo") or row.get("messageId") or key,
                "messages": [
                    {"filename": m.get("filename"), "subject": m.get("subject"), "messageId": m.get("messageId")}
                    for m in group
                ],
            }
        )
    return json.dumps(
        {
            "job": job.name,
            "jobId": job.id,
            "outputDir": str(folder),
            "count": total,
            "messages": messages,
            "threads": threads,
        },
        indent=2,
    )


@mcp.tool()
def read_message(path: str = "", job_name: str = "", filename: str = "") -> str:
    """Read headers and body text from one exported .eml.

    Prefer job_name + filename. A raw path is allowed only if it resolves under
    a configured job outputDir and ends with .eml.
    """
    try:
        eml = _resolve_eml_path(path=path, job_name=job_name, filename=filename)
    except ValueError as exc:
        return json.dumps({"error": str(exc)})
    if not eml.is_file():
        return json.dumps({"error": f"file not found: {eml}"})
    raw = eml.read_bytes()
    msg = email.message_from_bytes(raw)
    return json.dumps(
        {
            "path": str(eml),
            "from": _decode_hdr(msg.get("From")),
            "to": _decode_hdr(msg.get("To")),
            "cc": _decode_hdr(msg.get("Cc")),
            "subject": _decode_hdr(msg.get("Subject")),
            "date": msg.get("Date") or "",
            "messageId": msg.get("Message-ID") or msg.get("Message-Id") or "",
            "inReplyTo": msg.get("In-Reply-To") or "",
            "references": msg.get("References") or "",
            "body": _body_text(msg),
        },
        indent=2,
    )


@mcp.tool()
def compose_draft(path: str = "", markdown: str = "") -> str:
    """Open a Mail draft from a Markdown email file (or inline markdown). Never sends.

    Front-matter: To/Cc/Bcc/Subject/From/In-Reply-To/Reply/Attach/Format.
    Attach paths are relative to the .md file's folder (no ``..``, ``~/``, or absolute).
    Uses AppleScript (native reply quote; GUI Attach Files for reply+attachments).
    """
    try:
        if path:
            md_path = Path(path).expanduser()
            if not md_path.is_file():
                return json.dumps({"error": f"file not found: {md_path}"})
            result = _compose_draft(md_path)
        elif markdown.strip():
            result = compose_markdown_text(markdown)
        else:
            return json.dumps({"error": "provide path or markdown"})
        return json.dumps(result, indent=2)
    except Exception as exc:
        return json.dumps({"ok": False, "error": str(exc)}, indent=2)


@mcp.tool()
def check_matches(
    job_name: str | None = None,
    job_id: str | None = None,
) -> str:
    """Dry-run: count how many Apple Mail messages currently match a job.

    Pass ``job_name`` (or ``job_id``). Other arguments are optional.
    """
    return json.dumps(
        _call_export(job_name=job_name, job_id=job_id, dry_run=True),
        indent=2,
    )


@mcp.tool()
def export_job(
    job_name: str | None = None,
    job_id: str | None = None,
    force_full: bool | None = False,
) -> str:
    """Export matching messages from Apple Mail into the job's folder.

    Pass ``job_name`` (or ``job_id``). Incremental unless ``force_full`` is true.
    ``job_id`` and ``force_full`` may be omitted.
    """
    payload = _call_export(
        job_name=job_name,
        job_id=job_id,
        force_full=force_full,
        dry_run=False,
    )
    if payload.get("ok"):
        try:
            job = _find_job(job_id=job_id or None, job_name=job_name or None)
            write_how_to(Path(job.output_dir), mailbox_name=job.name)
        except Exception:
            pass
    return json.dumps(payload, indent=2)


@mcp.tool()
def clear_target(job_name: str = "", job_id: str = "") -> str:
    """Delete all .eml files and .exported-ids.json in a job's export folder.

    Only runs when the folder is a configured job outputDir and contains
    MailExporter markers (_how_to_use.md or .exported-ids.json).
    """
    try:
        job = _find_job(job_id=job_id or None, job_name=job_name or None)
        folder = Path(job.output_dir).expanduser()
        _assert_clearable_export_folder(folder)
    except ValueError as exc:
        return json.dumps({"error": str(exc), "ok": False})
    removed = 0
    for p in folder.glob("*.eml"):
        p.unlink(missing_ok=True)
        removed += 1
    state = folder / _EXPORT_MARKER
    if state.is_file():
        state.unlink()
    write_how_to(folder, mailbox_name=job.name)
    return json.dumps(
        {
            "ok": True,
            "job": job.name,
            "outputDir": str(folder),
            "removedEml": removed,
        },
        indent=2,
    )


@mcp.tool()
def write_howto(job_name: str = "", job_id: str = "") -> str:
    """Create or refresh `_how_to_use.md`. With no job, rewrite every export folder."""
    if not job_name.strip() and not job_id.strip():
        jobs = load_jobs(_config_path()).jobs
        paths = sync_how_to_all(jobs)
        return json.dumps(
            {
                "ok": True,
                "wrote": [str(p) for p in paths],
                "count": len(paths),
            },
            indent=2,
        )
    job = _find_job(job_id=job_id or None, job_name=job_name or None)
    path = write_how_to(Path(job.output_dir), mailbox_name=job.name)
    return json.dumps({"wrote": str(path), "job": job.name}, indent=2)


def _job_row(j: Job) -> dict[str, Any]:
    return {
        "id": j.id,
        "name": j.name,
        "outputDir": j.output_dir,
        "includeSent": j.include_sent,
        "includeBin": j.include_bin,
        "includeThread": j.include_thread,
    }


@mcp.tool()
def list_drafts(job_name: str = "", job_id: str = "") -> str:
    """List Markdown files in a job's Drafts/ and Sent/ folders."""
    job = _find_job(job_id=job_id or None, job_name=job_name or None)
    folder = Path(job.output_dir).expanduser()
    drafts = folder / DRAFTS_SUBDIR
    sent = folder / SENT_SUBDIR

    def _md(root: Path) -> list[dict[str, str]]:
        if not root.is_dir():
            return []
        rows = []
        for p in sorted(root.glob("*.md"), key=lambda x: x.name):
            rows.append({"filename": p.name, "path": str(p)})
        return rows

    return json.dumps(
        {
            "job": job.name,
            "jobId": job.id,
            "outputDir": str(folder),
            "drafts": _md(drafts),
            "sent": _md(sent),
        },
        indent=2,
    )


@mcp.tool()
def create_job(
    name: str,
    output_dir: str,
    match_json: str = "",
    include_sent: bool = True,
    include_bin: bool = False,
    include_thread: bool = False,
) -> str:
    """Create a MailExporter job. match_json is a MatchSpec object (same shape as jobs.json)."""
    name = name.strip()
    output_dir = output_dir.strip()
    if not name:
        return json.dumps({"ok": False, "error": "name required"})
    if not output_dir:
        return json.dumps({"ok": False, "error": "output_dir required"})
    raw_match: dict[str, Any]
    if match_json.strip():
        try:
            parsed = json.loads(match_json)
        except json.JSONDecodeError as exc:
            return json.dumps({"ok": False, "error": f"match_json: {exc}"})
        if not isinstance(parsed, dict):
            return json.dumps({"ok": False, "error": "match_json must be an object"})
        raw_match = parsed
    else:
        raw_match = {
            "conjunction": "any",
            "conditions": [
                {"field": "entire", "op": "contains", "values": [name]}
            ],
        }
    try:
        match = parse_match(raw_match)
    except Exception as exc:
        return json.dumps({"ok": False, "error": str(exc)})
    path = _config_path()
    jobs = load_jobs(path)
    if any(j.name.lower() == name.lower() for j in jobs.jobs):
        return json.dumps({"ok": False, "error": f"job already exists: {name}"})
    import uuid

    job = Job(
        id=str(uuid.uuid4()),
        name=name,
        output_dir=output_dir,
        match=match,
        include_sent=include_sent,
        include_bin=include_bin,
        include_thread=include_thread,
    )
    jobs.jobs.append(job)
    save_jobs(jobs, path)
    try:
        write_how_to(Path(output_dir), mailbox_name=name)
    except Exception:
        pass
    return json.dumps({"ok": True, "job": _job_row(job), "config": str(path)}, indent=2)


@mcp.tool()
def edit_job(
    job_name: str = "",
    job_id: str = "",
    name: str = "",
    output_dir: str = "",
    match_json: str = "",
    include_sent: str = "",
    include_bin: str = "",
    include_thread: str = "",
) -> str:
    """Update an existing job. Empty strings leave that field unchanged."""
    try:
        job = _find_job(job_id=job_id or None, job_name=job_name or None)
    except ValueError as exc:
        return json.dumps({"ok": False, "error": str(exc)})
    path = _config_path()
    jobs = load_jobs(path)
    target = None
    for j in jobs.jobs:
        if j.id == job.id:
            target = j
            break
    if target is None:
        return json.dumps({"ok": False, "error": "job not found after reload"})
    if name.strip():
        target.name = name.strip()
    if output_dir.strip():
        target.output_dir = output_dir.strip()
    if match_json.strip():
        try:
            parsed = json.loads(match_json)
            if not isinstance(parsed, dict):
                raise ValueError("match_json must be an object")
            target.match = parse_match(parsed)
        except (json.JSONDecodeError, ValueError) as exc:
            return json.dumps({"ok": False, "error": str(exc)})

    def _opt_bool(raw: str, current: bool) -> bool:
        s = raw.strip().lower()
        if not s:
            return current
        if s in ("1", "true", "yes"):
            return True
        if s in ("0", "false", "no"):
            return False
        return current

    target.include_sent = _opt_bool(include_sent, target.include_sent)
    target.include_bin = _opt_bool(include_bin, target.include_bin)
    target.include_thread = _opt_bool(include_thread, target.include_thread)
    save_jobs(jobs, path)
    return json.dumps({"ok": True, "job": _job_row(target), "config": str(path)}, indent=2)


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
