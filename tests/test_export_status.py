"""last-export.json so the Mac app can refresh “N new” after MCP/CLI export."""

from __future__ import annotations

import json
from pathlib import Path

from engine.export_status import last_export_path, publish_export_results


def test_publish_export_results_writes_counts(tmp_path: Path) -> None:
    path = last_export_path()
    wrote = publish_export_results(
        {
            "ok": True,
            "line": "2 new",
            "results": [
                {
                    "id": "job-1",
                    "name": "Helen Mortgage",
                    "newlyWritten": 2,
                    "matchCount": 10,
                    "line": "2 new",
                    "dryRun": False,
                }
            ],
        }
    )
    assert wrote == path
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["results"][0]["newlyWritten"] == 2
    assert data["results"][0]["id"] == "job-1"


def test_publish_skips_dry_run(tmp_path: Path) -> None:
    wrote = publish_export_results(
        {
            "ok": True,
            "line": "4 matches",
            "results": [{"id": "j", "dryRun": True, "newlyWritten": 0, "matchCount": 4}],
        }
    )
    assert wrote is None
    assert not last_export_path().exists()


def test_run_export_publishes_last_export(tmp_path: Path, monkeypatch) -> None:
    from engine.cli import run_export
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job
    from unittest.mock import patch

    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(tmp_path / "out")
    save_jobs(JobsFile(jobs=[job]), config)
    with patch("engine.cli.run_job") as run_job:
        run_job.return_value = {
            "id": job.id,
            "name": job.name,
            "newlyWritten": 3,
            "matchCount": 8,
            "line": "3 new",
            "countMatch": True,
            "dryRun": False,
        }
        payload, code = run_export(
            config=str(config),
            job_id=None,
            job_name=job.name,
            dry_run=False,
            force_full=False,
        )
    assert code == 0
    assert payload["ok"] is True
    data = json.loads(last_export_path().read_text(encoding="utf-8"))
    assert data["results"][0]["newlyWritten"] == 3


def test_run_export_dry_run_does_not_publish(tmp_path: Path) -> None:
    from engine.cli import run_export
    from engine.jobs import JobsFile, save_jobs, seed_dhl_job
    from unittest.mock import patch

    config = tmp_path / "jobs.json"
    job = seed_dhl_job()
    job.output_dir = str(tmp_path / "out")
    save_jobs(JobsFile(jobs=[job]), config)
    with patch("engine.cli.run_job") as run_job:
        run_job.return_value = {
            "id": job.id,
            "name": job.name,
            "newlyWritten": 0,
            "matchCount": 4,
            "line": "4 matches",
            "countMatch": True,
            "dryRun": True,
        }
        run_export(
            config=str(config),
            job_id=None,
            job_name=job.name,
            dry_run=True,
            force_full=False,
        )
    assert not last_export_path().exists()
