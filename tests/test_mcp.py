"""MCP smoke: import + compose_draft / read_message sandbox."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest


def test_mcp_module_imports() -> None:
    import mailexporter_mcp as m

    assert m.mcp is not None
    assert callable(m.list_jobs)
    assert callable(m.compose_draft)


def test_mcp_list_jobs_with_tmpdir(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job

    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(tmp_path / "out")
    save_jobs(JobsFile(jobs=[job]), config)
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))

    import importlib
    import mailexporter_mcp as m

    importlib.reload(m)

    raw = m.list_jobs()
    data = json.loads(raw)
    assert data["config"] == str(config)
    assert len(data["jobs"]) == 1
    assert data["jobs"][0]["name"] == "DHL"


def test_mcp_compose_draft_routes(tmp_path: Path) -> None:
    md = tmp_path / "reply.md"
    (tmp_path / "a.pdf").write_bytes(b"%PDF")
    md.write_text(
        "---\n"
        "To: a@b.com\n"
        "Subject: Re: x\n"
        "In-Reply-To: <id@x>\n"
        "Attach: a.pdf\n"
        "---\n"
        "\n"
        "Thanks\n",
        encoding="utf-8",
    )
    import mailexporter_mcp as m

    with patch("mailexporter_mcp._compose_draft") as compose:
        compose.return_value = {"ok": True, "via": "mail"}
        raw = m.compose_draft(path=str(md))
    data = json.loads(raw)
    assert data["ok"] is True
    assert data["via"] == "mail"
    compose.assert_called_once()


def test_mcp_compose_draft_missing_args() -> None:
    import mailexporter_mcp as m

    data = json.loads(m.compose_draft())
    assert "error" in data


def test_mcp_read_message_requires_job_sandbox(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, repo_root: Path
) -> None:
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job

    out = tmp_path / "out"
    out.mkdir()
    (out / ".exported-ids.json").write_text('{"ids":[]}', encoding="utf-8")
    eml = out / "msg.eml"
    eml.write_text(
        "From: a@b.com\nTo: c@d.com\nSubject: Hi\nMessage-ID: <x@y>\n\nBody\n",
        encoding="utf-8",
    )

    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(out)
    save_jobs(JobsFile(jobs=[job]), config)
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))

    import importlib
    import mailexporter_mcp as m

    importlib.reload(m)

    data = json.loads(m.read_message(job_name="DHL", filename="msg.eml"))
    assert data.get("error") is None
    assert data["subject"] == "Hi"

    # Path under job folder is ok
    data2 = json.loads(m.read_message(path=str(eml)))
    assert data2.get("error") is None

    # Arbitrary path outside jobs is denied
    outside = repo_root / "README.md"
    denied = json.loads(m.read_message(path=str(outside)))
    assert "error" in denied


def test_mcp_clear_target_requires_markers(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job

    out = tmp_path / "out"
    out.mkdir()
    (out / "a.eml").write_text("x", encoding="utf-8")

    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(out)
    save_jobs(JobsFile(jobs=[job]), config)
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))

    import importlib
    import mailexporter_mcp as m

    importlib.reload(m)

    # No marker yet → refuse
    bad = json.loads(m.clear_target(job_name="DHL"))
    assert bad.get("ok") is False
    assert "error" in bad
    assert (out / "a.eml").is_file()

    (out / ".exported-ids.json").write_text('{"ids":[]}', encoding="utf-8")
    with patch("mailexporter_mcp.write_how_to") as wh:
        wh.return_value = out / "_how_to_use.md"
        ok = json.loads(m.clear_target(job_name="DHL"))
    assert ok.get("ok") is True
    assert ok["removedEml"] == 1
    assert not (out / "a.eml").exists()


def test_mcp_list_messages_includes_headers(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job

    out = tmp_path / "out"
    out.mkdir()
    (out / "msg.eml").write_text(
        "From: a@b.com\nTo: c@d.com\nSubject: Hi\nDate: Wed, 5 Mar 2026 10:00:00 +0000\n"
        "Message-ID: <x@y>\nIn-Reply-To: <z@y>\n\nBody\n",
        encoding="utf-8",
    )
    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(out)
    save_jobs(JobsFile(jobs=[job]), config)
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))

    import importlib
    import mailexporter_mcp as m

    importlib.reload(m)
    data = json.loads(m.list_messages(job_name="DHL"))
    assert data["count"] == 1
    assert data["messages"][0]["subject"] == "Hi"
    assert data["messages"][0]["from"] == "a@b.com"
    assert data["messages"][0]["messageId"] == "<x@y>"
    assert data["threads"]


def test_mcp_create_edit_and_list_drafts(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    config = tmp_path / "jobs.json"
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))
    import importlib
    import mailexporter_mcp as m

    importlib.reload(m)
    created = json.loads(
        m.create_job(
            name="Invoices",
            output_dir=str(tmp_path / "inv"),
            match_json=json.dumps(
                {
                    "conjunction": "any",
                    "conditions": [
                        {"field": "subject", "op": "contains", "values": ["invoice"]}
                    ],
                }
            ),
        )
    )
    assert created["ok"] is True
    assert created["job"]["name"] == "Invoices"

    drafts = tmp_path / "inv" / "Drafts"
    drafts.mkdir(parents=True, exist_ok=True)
    (drafts / "001_a_hello.md").write_text("---\nTo: a@b.com\nSubject: x\n---\n\nhi\n")

    listed = json.loads(m.list_drafts(job_name="Invoices"))
    assert listed["drafts"][0]["filename"] == "001_a_hello.md"

    edited = json.loads(m.edit_job(job_name="Invoices", include_thread="true"))
    assert edited["ok"] is True
    assert edited["job"]["includeThread"] is True


def test_mcp_export_job_mocked(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job

    out = tmp_path / "out"
    out.mkdir()
    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(out)
    save_jobs(JobsFile(jobs=[job]), config)
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(config))
    import importlib
    import mailexporter_mcp as m

    importlib.reload(m)
    with patch("mailexporter_mcp._run_engine") as run, patch(
        "mailexporter_mcp.write_how_to"
    ) as wh:
        run.return_value = {"ok": True, "results": [{"matchCount": 3}]}
        wh.return_value = out / "_how_to_use.md"
        data = json.loads(m.export_job(job_name="DHL"))
        dry = json.loads(m.check_matches(job_name="DHL"))
    assert data["ok"] is True
    assert dry["ok"] is True
    run.assert_called()
