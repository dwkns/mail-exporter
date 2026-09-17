"""Howto generator is the single source of truth."""

from pathlib import Path

from engine.howto import HOW_TO_FILENAME, how_to_markdown, how_to_template, sync_how_to_all, write_how_to
from engine.jobs import Job
from engine.criteria import MatchSpec


def _empty_match() -> MatchSpec:
    return MatchSpec(conjunction="all", groups=[])


def test_howto_says_export_not_smart_mailbox() -> None:
    text = how_to_markdown(mailbox_name="DHL", output_dir="/tmp/out/Email", project_dir="/tmp/out")
    assert "Smart mailbox" not in text
    assert "Export job: **DHL**" in text
    assert "never leaves this Mac" in text
    assert "First read" in text
    assert "more background" in text
    assert "what to do next" in text


def test_howto_tells_assistant_to_reread_after_update() -> None:
    text = how_to_markdown(mailbox_name="DHL", output_dir="/tmp/out/Email")
    assert "Re-read `how_to_use.md`" in text
    assert "STATUS.md" in text


def test_template_placeholders() -> None:
    text = how_to_template()
    assert "{{MAILBOX_NAME}}" in text
    assert "{{OUTPUT_DIR}}" in text
    assert "{{PROJECT_DIR}}" in text
    assert "Smart mailbox" not in text


def test_resources_template_matches_generator() -> None:
    root = Path(__file__).resolve().parents[1]
    bundled = (root / "apps/MailExporter/Resources/how_to_use.md").read_text(encoding="utf-8")
    assert bundled == how_to_template()


def test_write_how_to_at_project_root(tmp_path: Path) -> None:
    email = tmp_path / "Claim" / "Email"
    email.mkdir(parents=True)
    stale = email / "_how_to_use.md"
    stale.write_text("old guide\n", encoding="utf-8")
    wrote = write_how_to(email, mailbox_name="Claim")
    assert wrote == tmp_path / "Claim" / HOW_TO_FILENAME
    body = wrote.read_text(encoding="utf-8")
    assert "old guide" not in body
    assert "Export job: **Claim**" in body
    assert "First read" in body
    assert not stale.exists()
    assert (tmp_path / "Claim" / "STATUS.md").is_file()
    assert (tmp_path / "Claim" / "Documents").is_dir()


def test_sync_how_to_all_skips_missing_folders(tmp_path: Path) -> None:
    present = tmp_path / "Here" / "Email"
    present.mkdir(parents=True)
    jobs = [
        Job(id="1", name="Here", output_dir=str(present), match=_empty_match()),
        Job(id="2", name="Gone", output_dir=str(tmp_path / "missing"), match=_empty_match()),
        Job(id="3", name="Empty", output_dir="", match=_empty_match()),
    ]
    wrote = sync_how_to_all(jobs)
    assert [p.parent.name for p in wrote] == ["Here"]
    assert (tmp_path / "Here" / "how_to_use.md").is_file()
    assert "Export job: **Here**" in (tmp_path / "Here" / "how_to_use.md").read_text(
        encoding="utf-8"
    )
