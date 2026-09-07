"""Compose Mail drafts via AppleScript (Make Mail Draft)."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from engine.draft_md import parse_markdown_draft, resolve_attachments


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def applescript_path() -> Path | None:
    bundled = (
        _repo_root()
        / "apps/MailExporter/MailExporter.app/Contents/Resources/MakeMailDraft.applescript"
    )
    src = _repo_root() / "apps/MailExporter/Resources/MakeMailDraft.applescript"
    if bundled.is_file():
        return bundled
    if src.is_file():
        return src
    return None


def compose_via_applescript(md_path: Path) -> dict:
    script = applescript_path()
    if script is None:
        return {"ok": False, "via": "mail", "error": "MakeMailDraft.applescript not found"}
    # Reject absolute/~ Attach: paths before Mail (missing files still open).
    try:
        text = md_path.read_text(encoding="utf-8")
        spec = parse_markdown_draft(text, source_path=md_path)
        if spec.attach:
            resolve_attachments(spec)
    except (OSError, ValueError) as exc:
        return {"ok": False, "via": "mail", "error": str(exc), "path": str(md_path)}

    proc = subprocess.run(
        ["/usr/bin/osascript", str(script), str(md_path)],
        capture_output=True,
        text=True,
    )
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    return {
        "ok": proc.returncode == 0,
        "via": "mail",
        "path": str(md_path),
        "result": out or "OK",
        "stderr": err or None,
        "exit": proc.returncode,
    }


def compose_draft(md_path: Path, **_kwargs) -> dict:
    """Open a Mail draft from a Markdown file. Extra kwargs ignored (compat)."""
    md_path = md_path.expanduser().resolve()
    if not md_path.is_file():
        return {"ok": False, "error": f"file not found: {md_path}"}
    return compose_via_applescript(md_path)


def compose_markdown_text(markdown: str, **kwargs) -> dict:
    fd, name = tempfile.mkstemp(prefix="mailexporter-", suffix=".md")
    os.close(fd)
    path = Path(name)
    try:
        path.write_text(markdown, encoding="utf-8")
        return compose_draft(path, **kwargs)
    finally:
        path.unlink(missing_ok=True)
