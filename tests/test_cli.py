"""CLI: python -m engine seed / list / append-draft (tmpdir config, mocked compose)."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

from engine.cli import main
from engine.jobs import load_jobs


def test_seed_and_list(tmp_path: Path, capsys) -> None:
    config = tmp_path / "jobs.json"
    assert main(["--config", str(config), "seed"]) == 0
    out = capsys.readouterr().out
    assert str(config) in out

    jobs = load_jobs(config)
    assert len(jobs.jobs) >= 2
    names = {j.name.lower() for j in jobs.jobs}
    assert "receipts" in names
    assert "dhl" in names

    # Idempotent seed
    assert main(["--config", str(config), "seed"]) == 0
    assert len(load_jobs(config).jobs) == len(jobs.jobs)
    capsys.readouterr()  # discard seed stdout

    assert main(["--config", str(config), "list"]) == 0
    listed = json.loads(capsys.readouterr().out)
    assert "jobs" in listed
    assert len(listed["jobs"]) == len(jobs.jobs)


def test_append_draft_cli(tmp_path: Path, capsys) -> None:
    md = tmp_path / "d.md"
    md.write_text(
        "---\nTo: a@b.com\nSubject: Hi\n---\n\nHello\n",
        encoding="utf-8",
    )
    with patch("engine.cli.compose_draft") as compose:
        compose.return_value = {
            "ok": True,
            "via": "mail",
            "path": str(md),
            "result": "OK",
        }
        code = main(["append-draft", str(md)])
    assert code == 0
    compose.assert_called_once()
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["results"][0]["via"] == "mail"


def test_append_draft_cli_failure(tmp_path: Path, capsys) -> None:
    md = tmp_path / "d.md"
    md.write_text("---\nTo: a@b.com\nSubject: x\n---\n\ny\n", encoding="utf-8")
    with patch("engine.cli.compose_draft") as compose:
        compose.return_value = {"ok": False, "error": "boom"}
        code = main(["append-draft", str(md)])
    assert code == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False
