"""CLI: python -m engine seed / list / append-draft (tmpdir config, mocked compose)."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

from engine.cli import main, run_export
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


def test_export_does_not_rewrite_jobs_json(tmp_path: Path) -> None:
    config = tmp_path / "jobs.json"
    raw = {
        "jobs": [
            {
                "id": "job-1",
                "name": "Tracked",
                "outputDir": str(tmp_path / "out"),
                "bookmark": "Ym9va21hcms=",
                "includeSent": True,
                "includeBin": False,
                "match": {
                    "conjunction": "any",
                    "conditions": [
                        {"field": "entire", "op": "contains", "values": ["x"]}
                    ],
                },
            }
        ]
    }
    config.write_text(json.dumps(raw, indent=2) + "\n", encoding="utf-8")
    before = config.read_text(encoding="utf-8")
    with patch("engine.cli.run_job") as run_job:
        run_job.return_value = {
            "id": "job-1",
            "name": "Tracked",
            "line": "Tracked: 0 copied",
            "countMatch": True,
            "newlyWritten": 0,
            "dryRun": False,
        }
        payload, code = run_export(
            config=str(config),
            job_id=None,
            job_name=None,
            dry_run=False,
            force_full=False,
        )
    assert code == 0
    assert payload["ok"] is True
    assert config.read_text(encoding="utf-8") == before
    assert "Ym9va21hcms=" in config.read_text(encoding="utf-8")


def test_draft_alias_matches_append_draft(tmp_path: Path, capsys) -> None:
    md = tmp_path / "d.md"
    md.write_text("---\nTo: a@b.com\nSubject: Hi\n---\n\nHello\n", encoding="utf-8")
    with patch("engine.cli.compose_draft") as compose:
        compose.return_value = {"ok": True, "via": "mail", "path": str(md)}
        code = main(["draft", str(md)])
    assert code == 0
    compose.assert_called_once()
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is True


def test_dry_run_allows_unsaved_job_without_output_dir(tmp_path: Path) -> None:
    config = tmp_path / "preview.json"
    config.write_text(
        json.dumps(
            {
                "jobs": [
                    {
                        "id": "draft-1",
                        "name": "Unsaved Claim",
                        "outputDir": "",
                        "match": {
                            "conjunction": "any",
                            "conditions": [
                                {
                                    "field": "entire",
                                    "op": "contains",
                                    "values": ["invoice"],
                                }
                            ],
                        },
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    with patch("engine.cli.run_job") as run_job:
        run_job.return_value = {
            "line": "1 match",
            "matchCount": 1,
            "dryRun": True,
            "countMatch": True,
        }
        payload, code = run_export(
            config=str(config),
            job_id="draft-1",
            job_name=None,
            dry_run=True,
            force_full=False,
        )
    assert code == 0
    assert payload["ok"] is True
    assert payload["results"][0]["matchCount"] == 1
    job = run_job.call_args.args[0]
    assert job.id == "draft-1"
    assert job.output_dir == ""
    assert run_job.call_args.kwargs["dry_run"] is True


def test_dry_run_unsaved_new_project_empty_search_row(
    tmp_path: Path, monkeypatch
) -> None:
    """New Project Check Matches: no outputDir yet, default empty condition row."""
    config = tmp_path / "preview.json"
    mail = tmp_path / "mail"
    mail.mkdir()
    config.write_text(
        json.dumps(
            {
                "jobs": [
                    {
                        "id": "draft-new",
                        "name": "New Project",
                        "outputDir": "",
                        "mailRoot": str(mail),
                        "match": {
                            "conjunction": "all",
                            "groups": [
                                {
                                    "conjunction": "any",
                                    "conditions": [
                                        {
                                            "field": "entire",
                                            "op": "contains",
                                            "values": [],
                                        }
                                    ],
                                }
                            ],
                        },
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr("engine.export.candidate_paths", lambda *a, **k: [])
    payload, code = run_export(
        config=str(config),
        job_id="draft-new",
        job_name=None,
        dry_run=True,
        force_full=False,
    )
    assert code == 0
    assert payload["ok"] is True
    assert payload["results"][0]["matchCount"] == 0
    assert payload["results"][0]["dryRun"] is True


def test_export_rejects_unsaved_job_without_output_dir(tmp_path: Path) -> None:
    config = tmp_path / "preview.json"
    config.write_text(
        json.dumps(
            {
                "jobs": [
                    {
                        "id": "draft-1",
                        "name": "Unsaved Claim",
                        "outputDir": "",
                        "match": {
                            "conjunction": "any",
                            "conditions": [
                                {
                                    "field": "entire",
                                    "op": "contains",
                                    "values": ["invoice"],
                                }
                            ],
                        },
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    payload, code = run_export(
        config=str(config),
        job_id="draft-1",
        job_name=None,
        dry_run=False,
        force_full=False,
    )
    assert code == 1
    assert payload["ok"] is False
    assert "outputDir" in payload["error"]


def test_export_json_only_stdout(tmp_path: Path, capsys) -> None:
    config = tmp_path / "jobs.json"
    raw = {
        "jobs": [
            {
                "id": "job-1",
                "name": "Tracked",
                "outputDir": str(tmp_path / "out"),
                "match": {
                    "conjunction": "any",
                    "conditions": [
                        {"field": "entire", "op": "contains", "values": ["x"]}
                    ],
                },
            }
        ]
    }
    config.write_text(json.dumps(raw), encoding="utf-8")
    with patch("engine.cli.run_job") as run_job:
        run_job.return_value = {"line": "Up to date", "countMatch": True}
        code = main(["--config", str(config), "export", "--json"])
    assert code == 0
    out = capsys.readouterr().out.strip()
    assert out.startswith("{")
    payload = json.loads(out)
    assert payload["ok"] is True
