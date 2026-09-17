"""Case-file project layout around a MailExporter Email/ folder."""

from __future__ import annotations

import re
from pathlib import Path

EMAIL_DIR = "Email"
DOCUMENTS_DIR = "Documents"
NOTES_DIR = "Notes"
ARCHIVE_DIR = "_archive"
STATUS_FILENAME = "STATUS.md"
LEGACY_HOWTO = "_how_to_use.md"


def sanitized_folder_name(name: str) -> str:
    text = (name or "").strip()
    text = text.replace("/", "-").replace(":", "-")
    text = re.sub(r"\s+", " ", text).strip(" .")
    return text or "Untitled"


def default_parent() -> Path:
    return Path.home() / "Desktop" / "home"


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
