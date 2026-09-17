"""Howto generator is the single source of truth."""

from pathlib import Path

from engine.howto import how_to_markdown, how_to_template, sync_how_to_all, write_how_to
from engine.jobs import Job
from engine.criteria import MatchSpec


def _empty_match() -> MatchSpec:
    return MatchSpec(conjunction="all", groups=[])


def test_howto_says_export_not_smart_mailbox() -> None:
    text = how_to_markdown(mailbox_name="DHL", output_dir="/tmp/out")
    assert "Smart mailbox" not in text
    assert "Export: **DHL**" in text
    assert "never leaves this Mac" in text
    assert "no `..`" in text or "No `..`" in text


def test_howto_tells_assistant_to_reread_after_update() -> None:
    text = how_to_markdown(mailbox_name="DHL", output_dir="/tmp/out")
    assert "Re-read `_how_to_use.md`" in text
    assert "bundled instructions change" in text


def test_template_placeholders() -> None:
    text = how_to_template()
    assert "{{MAILBOX_NAME}}" in text
    assert "{{OUTPUT_DIR}}" in text
    assert "Smart mailbox" not in text


def test_resources_template_matches_generator() -> None:
    root = Path(__file__).resolve().parents[1]
    bundled = (root / "apps/MailExporter/Resources/_how_to_use.md").read_text(encoding="utf-8")
    assert bundled == how_to_template()


def test_write_how_to_overwrites_stale_copy(tmp_path: Path) -> None:
    folder = tmp_path / "export"
    folder.mkdir()
    stale = folder / "_how_to_use.md"
    stale.write_text("old guide\n", encoding="utf-8")
    wrote = write_how_to(folder, mailbox_name="DHL")
    body = wrote.read_text(encoding="utf-8")
    assert "old guide" not in body
    assert "Export: **DHL**" in body
    assert "Re-read `_how_to_use.md`" in body


def test_sync_how_to_all_skips_missing_folders(tmp_path: Path) -> None:
    present = tmp_path / "present"
    present.mkdir()
    jobs = [
        Job(id="1", name="Here", output_dir=str(present), match=_empty_match()),
        Job(id="2", name="Gone", output_dir=str(tmp_path / "missing"), match=_empty_match()),
        Job(id="3", name="Empty", output_dir="", match=_empty_match()),
    ]
    wrote = sync_how_to_all(jobs)
    assert [p.parent.name for p in wrote] == ["present"]
    assert (present / "_how_to_use.md").is_file()
    assert "Export: **Here**" in (present / "_how_to_use.md").read_text(encoding="utf-8")
