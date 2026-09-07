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

from engine.compose_draft import compose_draft as _compose_draft  # noqa: E402
from engine.compose_draft import compose_markdown_text  # noqa: E402
from engine.howto import HOW_TO_FILENAME, write_how_to  # noqa: E402
from engine.jobs import default_jobs_path, load_jobs  # noqa: E402

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


def _find_engine() -> tuple[list[str], Path]:
    """Return (argv_prefix, cwd) for running the engine."""
    env = os.environ.get("MAILEXPORTER_ENGINE", "").strip()
    candidates: list[Path] = []
    if env:
        candidates.append(Path(env))
    candidates.append(
        _REPO
        / "apps/MailExporter/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine"
    )
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return [str(path)], path.parent
    return [sys.executable, "-m", "engine"], _REPO


def _run_engine(args: list[str]) -> dict[str, Any]:
    prefix, cwd = _find_engine()
    config = _config_path()
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
    """List MailExporter smart mailboxes (jobs) and their export folders."""
    path = _config_path()
    jobs = load_jobs(path).jobs
    rows = [
        {
            "id": j.id,
            "name": j.name,
            "outputDir": j.output_dir,
            "includeSent": j.include_sent,
            "includeBin": j.include_bin,
        }
        for j in jobs
    ]
    return json.dumps({"config": str(path), "jobs": rows}, indent=2)


@mcp.tool()
def list_messages(job_name: str = "", job_id: str = "", limit: int = 100) -> str:
    """List exported .eml files for a job (newest filenames last)."""
    job = _find_job(job_id=job_id or None, job_name=job_name or None)
    folder = Path(job.output_dir).expanduser()
    if not folder.is_dir():
        return json.dumps({"error": f"folder missing: {folder}", "job": job.name})
    files = sorted(folder.glob("*.eml"), key=lambda p: p.name)
    if limit > 0:
        files = files[-limit:]
    return json.dumps(
        {
            "job": job.name,
            "jobId": job.id,
            "outputDir": str(folder),
            "count": len(list(folder.glob("*.eml"))),
            "messages": [{"filename": p.name, "path": str(p)} for p in files],
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
    Attach paths are relative to the .md file's folder (``..`` allowed; no ``~/`` or absolute).
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
def check_matches(job_name: str = "", job_id: str = "") -> str:
    """Dry-run: count how many Apple Mail messages currently match a job."""
    args = ["export", "--dry-run"]
    if job_id:
        args += ["--job-id", job_id]
    elif job_name:
        args += ["--job-name", job_name]
    return json.dumps(_run_engine(args), indent=2)


@mcp.tool()
def export_job(
    job_name: str = "",
    job_id: str = "",
    force_full: bool = False,
) -> str:
    """Export matching messages from Apple Mail into the job's folder (incremental unless force_full)."""
    args = ["export"]
    if job_id:
        args += ["--job-id", job_id]
    elif job_name:
        args += ["--job-name", job_name]
    if force_full:
        args.append("--force-full")
    payload = _run_engine(args)
    # Ensure howto exists after export
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
    """Create or refresh `_how_to_use.md` in a job's export folder."""
    job = _find_job(job_id=job_id or None, job_name=job_name or None)
    path = write_how_to(Path(job.output_dir), mailbox_name=job.name)
    return json.dumps({"wrote": str(path), "job": job.name}, indent=2)


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
