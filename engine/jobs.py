"""Job config load/save helpers."""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .criteria import MatchSpec, parse_match

SAMPLE_TERMS = [
    "receipt",
    "invoice",
    "order confirmation",
    "billing",
    "subscription",
]


@dataclass
class Job:
    id: str
    name: str
    output_dir: str
    match: MatchSpec
    include_sent: bool = True
    include_bin: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "outputDir": self.output_dir,
            "includeSent": self.include_sent,
            "includeBin": self.include_bin,
            "match": self.match.to_dict(),
        }


@dataclass
class JobsFile:
    jobs: list[Job] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {"jobs": [j.to_dict() for j in self.jobs]}


def default_jobs_path() -> Path:
    env = os.environ.get("MAILEXPORTER_CONFIG")
    if env:
        return Path(env).expanduser()
    icloud_path = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/MailExporter/jobs.json"
    if icloud_path.is_file():
        return icloud_path
    local_path = Path.home() / "Library/Application Support/MailExporter/jobs.json"
    if local_path.is_file():
        return local_path
    icloud_dir = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
    if icloud_dir.is_dir():
        return icloud_path
    return local_path


def parse_job(raw: dict[str, Any]) -> Job:
    jid = str(raw.get("id") or uuid.uuid4())
    name = str(raw.get("name") or "").strip() or "Untitled"
    output = str(raw.get("outputDir") or "").strip()
    if not output:
        raise ValueError(f"job {name!r}: outputDir required")
    match = parse_match(raw.get("match") if isinstance(raw.get("match"), dict) else None)
    return Job(
        id=jid,
        name=name,
        output_dir=output,
        match=match,
        include_sent=bool(raw.get("includeSent", True)),
        include_bin=bool(raw.get("includeBin", False)),
    )


def load_jobs(path: Path) -> JobsFile:
    if not path.is_file():
        return JobsFile(jobs=[])
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("jobs file root must be an object")
    raw_jobs = data.get("jobs") or []
    if not isinstance(raw_jobs, list):
        raise ValueError("jobs must be an array")
    return JobsFile(jobs=[parse_job(j) for j in raw_jobs if isinstance(j, dict)])


def save_jobs(jobs: JobsFile, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(jobs.to_dict(), indent=2) + "\n", encoding="utf-8")


def seed_sample_job() -> Job:
    return Job(
        id=str(uuid.uuid4()),
        name="Receipts",
        output_dir=str(
            Path.home() / "Desktop/MailExporter/Receipts"
        ),
        include_sent=True,
        include_bin=False,
        match=parse_match(
            {
                "conjunction": "any",
                "conditions": [
                    {"field": "entire", "op": "contains", "values": [term]}
                    for term in SAMPLE_TERMS
                ],
            }
        ),
    )


def seed_dhl_job() -> Job:
    return Job(
        id=str(uuid.uuid4()),
        name="DHL",
        output_dir=str(
            Path.home() / "Desktop/MailExporter/DHL"
        ),
        include_sent=True,
        include_bin=False,
        match=parse_match(
            {
                "conjunction": "all",
                "conditions": [
                    {
                        "field": "from",
                        "op": "contains",
                        "values": ["support@dhl.com", "tracking@dhl.com"],
                    },
                    {"field": "date", "op": "after", "date": "2026-01-01"},
                ],
            }
        ),
    )
