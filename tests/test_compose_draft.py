"""compose_draft: AppleScript-only Mail draft composition."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch
import sys

import pytest

from engine.compose_draft import applescript_path, compose_draft, compose_markdown_text


@pytest.fixture
def draft_md(tmp_path: Path) -> Path:
    att = tmp_path / "file.pdf"
    att.write_bytes(b"%PDF-1.4")
    md = tmp_path / "reply.md"
    md.write_text(
        "---\n"
        "To: a@b.com\n"
        "Subject: Re: quote\n"
        "In-Reply-To: <orig@example.com>\n"
        "Reply: reply\n"
        "Attach: file.pdf\n"
        "---\n"
        "\n"
        "Thanks.\n",
        encoding="utf-8",
    )
    return md


def test_missing_file() -> None:
    result = compose_draft(Path("/nonexistent/draft-xyz.md"))
    assert result["ok"] is False
    assert "not found" in result["error"]


def test_compose_via_applescript_missing_script(draft_md: Path) -> None:
    with patch("engine.compose_draft.applescript_path", return_value=None):
        result = compose_draft(draft_md)
    assert result["ok"] is False
    assert result["via"] == "mail"
    assert "not found" in result["error"]


def test_compose_via_applescript_runs_osascript(draft_md: Path, tmp_path: Path) -> None:
    script = tmp_path / "MakeMailDraft.applescript"
    script.write_text("-- stub\n", encoding="utf-8")
    proc = MagicMock(returncode=0, stdout="OK\n", stderr="")
    with (
        patch("engine.compose_draft.applescript_path", return_value=script),
        patch("engine.compose_draft.subprocess.run", return_value=proc) as run,
    ):
        result = compose_draft(draft_md)
    run.assert_called_once()
    args = run.call_args[0][0]
    assert args[0] == "/usr/bin/osascript"
    assert args[1] == str(script)
    assert args[2] == str(draft_md)
    assert result["ok"] is True
    assert result["via"] == "mail"


def test_rejects_absolute_attach_outside_project(tmp_path: Path) -> None:
    project = tmp_path / "Claim"
    drafts = project / "Email" / "Drafts"
    drafts.mkdir(parents=True)
    secret = tmp_path / "other" / "secret.txt"
    secret.parent.mkdir()
    secret.write_text("x", encoding="utf-8")
    md = drafts / "d.md"
    md.write_text(
        f"---\nTo: a@b.com\nSubject: x\nAttach: {secret}\n---\n\nhi\n",
        encoding="utf-8",
    )
    with patch("engine.compose_draft.applescript_path", return_value=tmp_path / "x.applescript"):
        result = compose_draft(md)
    assert result["ok"] is False
    assert "project" in result["error"].lower()


def test_parent_relative_attach_escaping_project_is_rejected(tmp_path: Path) -> None:
    project = tmp_path / "Claim"
    drafts = project / "Email" / "Drafts"
    outside = tmp_path / "outside"
    drafts.mkdir(parents=True)
    outside.mkdir()
    (outside / "scan.pdf").write_bytes(b"%PDF")
    md = drafts / "d.md"
    md.write_text(
        "---\nTo: a@b.com\nSubject: x\n"
        "Attach: ../../../outside/scan.pdf\n---\n\nhi\n",
        encoding="utf-8",
    )
    result = compose_draft(md)
    assert result["ok"] is False
    assert "project" in result["error"].lower()


def test_missing_attach_still_opens_mail(tmp_path: Path) -> None:
    md = tmp_path / "d.md"
    md.write_text(
        "---\nTo: a@b.com\nSubject: x\nAttach: gone.pdf\n---\n\nhi\n",
        encoding="utf-8",
    )
    script = tmp_path / "MakeMailDraft.applescript"
    script.write_text("-- stub\n", encoding="utf-8")
    proc = MagicMock(returncode=0, stdout="OK\n", stderr="")
    with (
        patch("engine.compose_draft.applescript_path", return_value=script),
        patch("engine.compose_draft.subprocess.run", return_value=proc) as run,
    ):
        result = compose_draft(md)
    run.assert_called_once()
    assert result["ok"] is True


def test_compose_markdown_text_persists_into_drafts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job

    out = tmp_path / "export"
    job = seed_dhl_job()
    job.output_dir = str(out)
    config = tmp_path / "jobs.json"
    save_jobs(JobsFile(jobs=[job]), config)
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))
    with patch("engine.compose_draft.compose_draft") as cd:
        cd.return_value = {"ok": True, "via": "mail"}
        result = compose_markdown_text("---\nTo: a@b.com\nSubject: x\n---\n\nhi\n")
    assert result["ok"] is True
    path_arg = cd.call_args[0][0]
    assert path_arg.suffix == ".md"
    assert path_arg.parent.name == "Drafts"
    assert path_arg.exists()


def test_applescript_path_from_installed_engine_layout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    resources = tmp_path / "MailExporter.app" / "Contents" / "Resources"
    engine_dir = resources / "MailExporterEngine"
    engine_dir.mkdir(parents=True)
    script = resources / "MakeMailDraft.applescript"
    script.write_text("-- stub\n", encoding="utf-8")
    exe = engine_dir / "MailExporterEngine"
    exe.write_text("x", encoding="utf-8")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(exe))
    monkeypatch.setattr(
        "engine.compose_draft.INSTALLED_APP_SCRIPT",
        tmp_path / "not-installed.applescript",
    )
    assert applescript_path() == script
