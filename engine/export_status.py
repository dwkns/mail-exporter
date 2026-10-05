"""Publish export results so the Mac app can refresh “N new” counts."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

_LAST_EXPORT_REL = Path("Library/Application Support/MailExporter/last-export.json")


def last_export_path() -> Path:
    env = (os.environ.get("MAILEXPORTER_LAST_EXPORT") or "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / _LAST_EXPORT_REL


def publish_export_results(payload: dict[str, Any]) -> Path | None:
    """Write last-export.json for a real export (not dry-run). Best-effort."""
    results = payload.get("results")
    if not isinstance(results, list) or not results:
        return None
    rows = [row for row in results if isinstance(row, dict)]
    if not rows:
        return None
    if all(bool(row.get("dryRun")) for row in rows):
        return None
    data = {
        "ok": bool(payload.get("ok")),
        "line": payload.get("line") or "",
        "results": [
            {
                "id": row.get("id"),
                "name": row.get("name"),
                "newlyWritten": row.get("newlyWritten"),
                "matchCount": row.get("matchCount"),
                "line": row.get("line"),
                "dryRun": bool(row.get("dryRun")),
            }
            for row in rows
        ],
    }
    path = last_export_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    except OSError:
        return None
    return path
