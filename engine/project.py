"""Case-file project layout around a MailExporter Email/ folder."""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

_REPO_SHARED = Path(__file__).resolve().parents[1] / "shared" / "project_layout.json"
_PACKAGE_SHARED = Path(__file__).resolve().with_name("project_layout.json")


@lru_cache(maxsize=1)
def _layout() -> dict[str, object]:
    for path in (_PACKAGE_SHARED, _REPO_SHARED):
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
    # Frozen / missing-file fallback — keep in sync with shared/project_layout.json.
    return {
        "email_dir": "Email",
        "documents_dir": "Documents",
        "notes_dir": "Notes",
        "archive_dir": "_archive",
        "status_filename": "STATUS.md",
        "howto_filename": "how_to_use.md",
        "legacy_howto_filename": "_how_to_use.md",
        "default_parent_segments": ["Desktop"],
    }


def _str(key: str) -> str:
    return str(_layout()[key])


EMAIL_DIR = _str("email_dir")
DOCUMENTS_DIR = _str("documents_dir")
NOTES_DIR = _str("notes_dir")
ARCHIVE_DIR = _str("archive_dir")
STATUS_FILENAME = _str("status_filename")
HOWTO_FILENAME = _str("howto_filename")
LEGACY_HOWTO = _str("legacy_howto_filename")


def sanitized_folder_name(name: str) -> str:
    text = (name or "").strip()
    text = text.replace("/", "-").replace(":", "-")
    text = re.sub(r"\s+", " ", text).strip(" .")
    return text or "Untitled"


def default_parent() -> Path:
    """First-run parent when the caller does not pass one (CLI / tests).

    The Mac app remembers the last chosen parent in UserDefaults; this Desktop
    default is only the portable fallback (not a personal nested path).
    """
    segments = _layout()["default_parent_segments"]
    assert isinstance(segments, list)
    path = Path.home()
    for part in segments:
        path = path / str(part)
    return path


def infer_project_root(path: Path) -> Path:
    """Project root from an Email/ path, a Drafts .md, or the folder itself."""
    p = Path(path).expanduser().resolve()
    if p.is_file():
        p = p.parent
    if p.name == "Drafts":
        p = p.parent
    if p.name == EMAIL_DIR:
        return p.parent
    return p


def email_dir(project_root: Path) -> Path:
    return Path(project_root).expanduser() / EMAIL_DIR


def ensure_project_layout(project_root: Path, *, mailbox_name: str = "") -> Path:
    """Create Email/Documents/Notes/_archive. Does not overwrite STATUS.md."""
    root = Path(project_root).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    email = root / EMAIL_DIR
    email.mkdir(exist_ok=True)
    (email / "Drafts").mkdir(exist_ok=True)
    (email / "Sent").mkdir(exist_ok=True)
    (root / DOCUMENTS_DIR).mkdir(exist_ok=True)
    (root / NOTES_DIR).mkdir(exist_ok=True)
    (root / ARCHIVE_DIR).mkdir(exist_ok=True)
    status = root / STATUS_FILENAME
    if not status.is_file():
        title = (mailbox_name or root.name).strip() or root.name
        status.write_text(
            f"# {title}\n\n"
            "Status: open\n\n"
            "## Where we are\n\n"
            "(one paragraph)\n\n"
            "## Last sent\n\n"
            "## Next action\n",
            encoding="utf-8",
        )
    return root


def create_project(name: str, parent: Path | None = None) -> Path:
    """Create `{parent}/{name}/` with the standard case-file layout. Returns the project root."""
    parent_path = Path(parent).expanduser() if parent else default_parent()
    parent_path.mkdir(parents=True, exist_ok=True)
    root = parent_path / sanitized_folder_name(name)
    return ensure_project_layout(root, mailbox_name=name)


def remove_legacy_howto(folder: Path) -> None:
    stale = Path(folder).expanduser() / LEGACY_HOWTO
    if stale.is_file():
        stale.unlink()
