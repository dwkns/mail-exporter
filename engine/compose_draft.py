"""Ask MailExporter.app to create a Mail draft. Never sends."""

from __future__ import annotations

import json
import re
import socket
import subprocess
import time
from pathlib import Path

from engine.draft_md import parse_markdown_draft, resolve_attachments

_ATTACHED_RE = re.compile(r"attached\s+(\d+)\s+of\s+(\d+)", re.I)
_APP_SOCKET = Path.home() / "Library/Application Support/MailExporter/cmd.sock"
_APP_BUNDLE = Path("/Applications/MailExporter.app")


def parse_attach_counts(text: str) -> tuple[int, int] | None:
    """Parse ``attached N of M`` from a draft result."""
    match = _ATTACHED_RE.search(text or "")
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def _ask_app(req: dict) -> dict:
    """Ask the MailExporter app. Same socket path and retry as the MCP tool."""

    def once() -> dict:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(600)
            sock.connect(str(_APP_SOCKET))
            sock.sendall((json.dumps(req) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
        if not buf:
            return {"ok": False, "error": "MailExporter returned nothing"}
        payload = json.loads(buf.split(b"\n", 1)[0])
        if not isinstance(payload, dict):
            return {"ok": False, "error": "MailExporter returned a non-object"}
        return payload

    try:
        return once()
    except (FileNotFoundError, ConnectionRefusedError, OSError):
        if _APP_BUNDLE.is_dir():
            subprocess.run(["/usr/bin/open", "-a", str(_APP_BUNDLE)], check=False)
        for _ in range(40):
            time.sleep(0.25)
            try:
                return once()
            except (FileNotFoundError, ConnectionRefusedError, OSError):
                continue
        return {
            "ok": False,
            "error": "MailExporter is not running, so it could not read your mail.",
        }


def _missing_attachments(spec, resolved: list[Path]) -> list[str]:
    """Names in Attach: that resolve_attachments skipped because the file is absent."""
    from engine.project import infer_project_root

    source = spec.source_path
    md_dir = (source.parent if source else Path.cwd()).resolve()
    project = infer_project_root(source).resolve() if source else md_dir
    got = {path.resolve() for path in resolved}
    missing: list[str] = []
    for raw in spec.attach:
        expanded = Path(raw).expanduser()
        if expanded.is_absolute() or raw.startswith("~"):
            candidates = [expanded.expanduser().resolve()]
        else:
            candidates = [(project / expanded).resolve(), (md_dir / expanded).resolve()]
        if not any(path in got and path.is_file() for path in candidates):
            missing.append(raw)
    return missing


def compose_draft(md_path: Path, **kwargs) -> dict:
    """Open a Mail draft from a Markdown file. Extra kwargs may set method or subject."""
    md_path = md_path.expanduser().resolve()
    if not md_path.is_file():
        return {"ok": False, "error": f"file not found: {md_path}"}
    try:
        text = md_path.read_text(encoding="utf-8")
        spec = parse_markdown_draft(text, source_path=md_path)
        if spec.attach:
            resolved = resolve_attachments(spec)
            missing = _missing_attachments(spec, resolved)
            if missing:
                return {
                    "ok": False,
                    "error": "attachment not found: " + ", ".join(missing),
                    "path": str(md_path),
                }
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc), "path": str(md_path)}

    req: dict = {"cmd": "compose", "path": str(md_path)}
    method = kwargs.get("method")
    subject = kwargs.get("subject")
    if method:
        req["method"] = method
    if subject:
        req["subject"] = subject
    payload = _ask_app(req)
    payload.setdefault("path", str(md_path))
    return payload


def compose_markdown_text(markdown: str, **kwargs) -> dict:
    from engine.howto import DRAFTS_SUBDIR
    from engine.jobs import default_jobs_path, load_jobs

    dest_dir: Path | None = None
    jobs = load_jobs(default_jobs_path()).jobs
    for job in jobs:
        folder = Path(job.output_dir).expanduser()
        drafts = folder / DRAFTS_SUBDIR
        if drafts.is_dir() or folder.is_dir():
            dest_dir = drafts
            dest_dir.mkdir(parents=True, exist_ok=True)
            break
    if dest_dir is None:
        dest_dir = Path.home() / "Library/Application Support/MailExporter/Drafts"
        dest_dir.mkdir(parents=True, exist_ok=True)
    path = dest_dir / f"compose-{int(time.time())}.md"
    path.write_text(markdown, encoding="utf-8")
    return compose_draft(path, **kwargs)
