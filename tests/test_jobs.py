"""Jobs load/save/seed (tmpdir only — no Mail)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from engine.criteria import match_message
from engine.jobs import (
    JobsFile,
    load_jobs,
    parse_job,
    save_jobs,
    seed_dhl_job,
    seed_sample_job,
)


def _msg(
    *,
    from_addr: str = "a@b.com",
    body: str = "hello",
    date_hdr: str = "Wed, 5 Mar 2026 10:00:00 +0000",
) -> bytes:
    return (
        f"From: {from_addr}\r\n"
        f"Subject: x\r\n"
        f"Date: {date_hdr}\r\n"
        f"Message-ID: <test@example.com>\r\n"
        f"\r\n"
        f"{body}\r\n"
    ).encode()


def test_load_missing_file_returns_empty(tmp_path: Path) -> None:
    path = tmp_path / "missing.json"
    jobs = load_jobs(path)
    assert jobs.jobs == []


def test_save_and_load_roundtrip(tmp_path: Path) -> None:
    path = tmp_path / "jobs.json"
    sample = seed_sample_job()
    sample.output_dir = str(tmp_path / "out-sample")
    dhl = seed_dhl_job()
    dhl.output_dir = str(tmp_path / "out-dhl")
    save_jobs(JobsFile(jobs=[sample, dhl]), path)

    loaded = load_jobs(path)
    assert len(loaded.jobs) == 2
    assert loaded.jobs[0].name == "Receipts"
    assert loaded.jobs[1].name == "DHL"
    assert loaded.jobs[0].include_sent is True
    assert loaded.jobs[1].include_bin is False

    raw = json.loads(path.read_text(encoding="utf-8"))
    assert "jobs" in raw
    assert raw["jobs"][0]["match"]["groups"]


def test_parse_job_requires_output_dir() -> None:
    with pytest.raises(ValueError, match="outputDir"):
        parse_job({"name": "X", "match": {"all": [{"field": "subject", "op": "contains", "values": ["a"]}]}})


def test_parse_job_defaults() -> None:
    job = parse_job(
        {
            "outputDir": "/tmp/out",
            "match": {
                "conjunction": "any",
                "conditions": [
                    {"field": "entire", "op": "contains", "values": ["hello"]}
                ],
            },
        }
    )
    assert job.name == "Untitled"
    assert job.id
    assert job.include_sent is True
    assert job.include_bin is False


def test_seed_sample_matches_known_term() -> None:
    job = seed_sample_job()
    hit = _msg(body="See your invoice for details")
    miss = _msg(body="unrelated newsletter")
    assert match_message(job.match, hit)
    assert not match_message(job.match, miss)


def test_seed_dhl_from_and_date() -> None:
    job = seed_dhl_job()
    hit = _msg(
        from_addr="DHL Express <support@dhl.com>",
        date_hdr="Wed, 5 Mar 2026 10:00:00 +0000",
    )
    miss_date = _msg(
        from_addr="support@dhl.com",
        date_hdr="Tue, 3 Dec 2025 10:00:00 +0000",
    )
    assert match_message(job.match, hit)
    assert not match_message(job.match, miss_date)


def test_job_to_dict_shape() -> None:
    job = seed_dhl_job()
    d = job.to_dict()
    assert set(d) >= {"id", "name", "outputDir", "includeSent", "includeBin", "match"}
    assert isinstance(d["match"], dict)


def test_default_jobs_path_env_override(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    custom = tmp_path / "custom-jobs.json"
    monkeypatch.setenv("MAILEXPORTER_CONFIG", str(custom))
    from engine.jobs import default_jobs_path
    assert default_jobs_path() == custom


def test_default_jobs_path_resolution(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("MAILEXPORTER_CONFIG", raising=False)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    from engine.jobs import default_jobs_path

    local_path = tmp_path / "Library/Application Support/MailExporter/jobs.json"
    ubiquity_dot = (
        tmp_path
        / "Library/Mobile Documents/iCloud.com~dwkns~MailExporter/Documents/jobs.json"
    )
    ubiquity_tilde = (
        tmp_path
        / "Library/Mobile Documents/iCloud~com~dwkns~MailExporter/Documents/jobs.json"
    )
    legacy_path = (
        tmp_path / "Library/Mobile Documents/com~apple~CloudDocs/MailExporter/jobs.json"
    )

    # Nothing exists -> local Application Support
    assert default_jobs_path() == local_path

    # Empty ubiquity directory is not enough
    ubiquity_dot.parent.mkdir(parents=True)
    assert default_jobs_path() == local_path

    # Local file wins over leftover CloudDocs
    local_path.parent.mkdir(parents=True, exist_ok=True)
    local_path.write_text("{}", encoding="utf-8")
    legacy_path.parent.mkdir(parents=True, exist_ok=True)
    legacy_path.write_text("{}", encoding="utf-8")
    assert default_jobs_path() == local_path

    # Real ubiquity file (tilde layout used on this Mac) wins over local + CloudDocs
    ubiquity_tilde.parent.mkdir(parents=True, exist_ok=True)
    ubiquity_tilde.write_text("{}", encoding="utf-8")
    assert default_jobs_path() == ubiquity_tilde

    # Dot-style ubiquity name is also recognized
    ubiquity_tilde.unlink()
    ubiquity_dot.write_text("{}", encoding="utf-8")
    assert default_jobs_path() == ubiquity_dot


def test_load_job_with_bookmark(tmp_path: Path) -> None:
    path = tmp_path / "jobs.json"
    raw = {
        "jobs": [
            {
                "id": "job-bm-1",
                "name": "Tracked Mailbox",
                "outputDir": str(tmp_path / "Target"),
                "bookmark": "Ym9va21hcms=",
                "match": {
                    "groups": [
                        {
                            "conjunction": "any",
                            "conditions": [{"field": "entire", "op": "contains", "value": "test"}],
                        }
                    ]
                },
            }
        ]
    }
    path.write_text(json.dumps(raw), encoding="utf-8")
    loaded = load_jobs(path)
    assert len(loaded.jobs) == 1
    assert loaded.jobs[0].name == "Tracked Mailbox"
    assert loaded.jobs[0].output_dir == str(tmp_path / "Target")
    assert loaded.jobs[0].extra.get("bookmark") == "Ym9va21hcms="
    save_jobs(loaded, path)
    assert json.loads(path.read_text(encoding="utf-8"))["jobs"][0]["bookmark"] == "Ym9va21hcms="


def test_pointer_wins_over_leftover_clouddocs(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("MAILEXPORTER_CONFIG", raising=False)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    from engine.jobs import default_jobs_path

    local_path = tmp_path / "Library/Application Support/MailExporter/jobs.json"
    pointer = tmp_path / "Library/Application Support/MailExporter/jobs-location"
    legacy_path = (
        tmp_path / "Library/Mobile Documents/com~apple~CloudDocs/MailExporter/jobs.json"
    )
    custom = tmp_path / "chosen" / "jobs.json"
    pointer.parent.mkdir(parents=True)
    legacy_path.parent.mkdir(parents=True)
    custom.parent.mkdir(parents=True)
    local_path.write_text("{}", encoding="utf-8")
    legacy_path.write_text("{}", encoding="utf-8")
    custom.write_text("{}", encoding="utf-8")
    pointer.write_text(str(custom) + "\n", encoding="utf-8")
    assert default_jobs_path() == custom


def test_local_pref_wins_over_leftover_ubiquity(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("MAILEXPORTER_CONFIG", raising=False)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    import plistlib

    from engine.jobs import default_jobs_path

    local_path = tmp_path / "Library/Application Support/MailExporter/jobs.json"
    ubiquity = (
        tmp_path
        / "Library/Mobile Documents/iCloud~com~dwkns~MailExporter/Documents/jobs.json"
    )
    prefs = tmp_path / "Library/Preferences/com.dwkns.MailExporter.plist"
    local_path.parent.mkdir(parents=True)
    ubiquity.parent.mkdir(parents=True)
    prefs.parent.mkdir(parents=True)
    local_path.write_text("{}", encoding="utf-8")
    ubiquity.write_text("{}", encoding="utf-8")
    prefs.write_bytes(plistlib.dumps({"storageLocation": "local"}))
    assert default_jobs_path() == local_path


