"""Case-file project layout."""

from pathlib import Path

from engine.project import (
    create_project,
    email_dir,
    ensure_project_layout,
    infer_project_root,
    sanitized_folder_name,
)


def test_create_project_layout(tmp_path: Path) -> None:
    root = create_project("NHS Appointment (Pelvis)", parent=tmp_path)
    assert root.name == "NHS Appointment (Pelvis)"
    assert (root / "Email" / "Drafts").is_dir()
    assert (root / "Email" / "Sent").is_dir()
    assert (root / "Documents").is_dir()
    assert (root / "Notes").is_dir()
    assert (root / "_archive").is_dir()
    status = (root / "STATUS.md").read_text(encoding="utf-8")
    assert "NHS Appointment (Pelvis)" in status
    assert "Status: open" in status
    ensure_project_layout(root, mailbox_name="Other")
    assert "Other" not in (root / "STATUS.md").read_text(encoding="utf-8")


def test_sanitized_folder_name() -> None:
    assert sanitized_folder_name("A / B: C") == "A - B- C"
    assert sanitized_folder_name("  ") == "Untitled"


def test_infer_project_root(tmp_path: Path) -> None:
    md = tmp_path / "Claim" / "Email" / "Drafts" / "001.md"
    md.parent.mkdir(parents=True)
    md.write_text("x")
    assert infer_project_root(md) == (tmp_path / "Claim").resolve()
    assert email_dir(tmp_path / "Claim") == tmp_path / "Claim" / "Email"
