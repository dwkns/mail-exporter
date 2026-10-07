"""compose_draft asks the app socket. It does not run AppleScript."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from engine.compose_draft import compose_draft, compose_markdown_text


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


def test_asks_app_socket(draft_md: Path) -> None:
    with patch("engine.compose_draft._ask_app") as ask:
        ask.return_value = {
            "ok": True,
            "result": "attached 1 of 1",
            "attached": 1,
            "requested": 1,
            "method": "upload",
        }
        result = compose_draft(draft_md, method="upload", subject="PROBE draft-creation")
    ask.assert_called_once()
    req = ask.call_args.args[0]
    assert req["cmd"] == "compose"
    assert req["path"] == str(draft_md)
    assert req["method"] == "upload"
    assert req["subject"] == "PROBE draft-creation"
    assert result["ok"] is True
    assert result["attached"] == 1
    assert result["requested"] == 1


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
    with patch("engine.compose_draft._ask_app") as ask:
        result = compose_draft(md)
    ask.assert_not_called()
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
    with patch("engine.compose_draft._ask_app") as ask:
        result = compose_draft(md)
    ask.assert_not_called()
    assert result["ok"] is False
    assert "project" in result["error"].lower()


def test_missing_attach_fails_before_mail(tmp_path: Path) -> None:
    md = tmp_path / "d.md"
    md.write_text(
        "---\nTo: a@b.com\nSubject: x\nAttach: gone.pdf\n---\n\nhi\n",
        encoding="utf-8",
    )
    with patch("engine.compose_draft._ask_app") as ask:
        result = compose_draft(md)
    ask.assert_not_called()
    assert result["ok"] is False
    assert "gone.pdf" in result["error"]
    assert "not found" in result["error"]


def test_parse_attach_counts() -> None:
    from engine.compose_draft import parse_attach_counts

    assert parse_attach_counts("OK") is None
    assert parse_attach_counts("attached 3 of 3") == (3, 3)
    assert parse_attach_counts("These attachments…\nattached 0 of 3\n") == (0, 3)


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
