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

_KNOWN_JOB_KEYS = {
    "id",
    "name",
    "outputDir",
    "match",
    "includeSent",
    "includeBin",
}

_POINTER_REL = Path("Library/Application Support/MailExporter/jobs-location")
_PREFS_REL = Path("Library/Preferences/com.dwkns.MailExporter.plist")
_LOCAL_JOBS_REL = Path("Library/Application Support/MailExporter/jobs.json")


@dataclass
class Job:
    id: str
    name: str
    output_dir: str
    match: MatchSpec
    include_sent: bool = True
    include_bin: bool = False
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "id": self.id,
            "name": self.name,
            "outputDir": self.output_dir,
            "includeSent": self.include_sent,
            "includeBin": self.include_bin,
            "match": self.match.to_dict(),
        }
        for key, value in self.extra.items():
            if key not in data:
                data[key] = value
        return data


@dataclass
class JobsFile:
    jobs: list[Job] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {"jobs": [j.to_dict() for j in self.jobs]}


def _ubiquity_jobs_candidates(home: Path) -> list[Path]:
    """On-disk names Apple uses for iCloud.com.dwkns.MailExporter."""
    mobile = home / "Library/Mobile Documents"
    return [
        mobile / "iCloud.com~dwkns~MailExporter/Documents/jobs.json",
        mobile / "iCloud~com~dwkns~MailExporter/Documents/jobs.json",
    ]


def _read_pointer(home: Path) -> Path | None:
    pointer = home / _POINTER_REL
    if not pointer.is_file():
        return None
    raw = pointer.read_text(encoding="utf-8").strip()
    if not raw:
        return None
    line = raw.splitlines()[0].strip()
    if not line or line.startswith("#"):
        return None
    path = Path(line).expanduser()
    if path.is_dir() or path.suffix.lower() != ".json":
        path = path / "jobs.json"
    return path


def _app_storage_preference(home: Path) -> tuple[str | None, str]:
    """Return (storageLocation, customStoragePath) from the Mac app's defaults."""
    plist_path = home / _PREFS_REL
    if not plist_path.is_file():
        return None, ""
    try:
        import plistlib

        data = plistlib.loads(plist_path.read_bytes())
    except Exception:
        return None, ""
    if not isinstance(data, dict):
        return None, ""
    loc = data.get("storageLocation")
    custom = data.get("customStoragePath") or ""
    loc_s = str(loc).strip().lower() if loc else None
    return loc_s, str(custom).strip()


def default_jobs_path() -> Path:
    """Resolve jobs.json the same way the macOS app does.

    1. ``MAILEXPORTER_CONFIG``
    2. Pointer written by the app (``…/MailExporter/jobs-location``)
    3. App Settings (UserDefaults): custom / local / iCloud
    4. Existing private ubiquity ``jobs.json`` (either on-disk name)
    5. Local Application Support

    Leftover iCloud Drive (CloudDocs) files are never preferred over Local.
    """
    env = os.environ.get("MAILEXPORTER_CONFIG")
    if env:
        return Path(env).expanduser()

    home = Path.home()
    pointed = _read_pointer(home)
    if pointed is not None:
        return pointed

    loc, custom = _app_storage_preference(home)
    if loc == "custom" and custom:
        path = Path(custom).expanduser()
        if path.is_dir() or path.suffix.lower() != ".json":
            path = path / "jobs.json"
        return path
    if loc == "local":
        return home / _LOCAL_JOBS_REL

    for ubi in _ubiquity_jobs_candidates(home):
        if ubi.is_file():
            return ubi
    return home / _LOCAL_JOBS_REL


def parse_job(raw: dict[str, Any]) -> Job:
    jid = str(raw.get("id") or uuid.uuid4())
    name = str(raw.get("name") or "").strip() or "Untitled"
    output = str(raw.get("outputDir") or "").strip()
    if not output:
        raise ValueError(f"job {name!r}: outputDir required")
    match = parse_match(raw.get("match") if isinstance(raw.get("match"), dict) else None)
    extra = {k: v for k, v in raw.items() if k not in _KNOWN_JOB_KEYS}
    return Job(
        id=jid,
        name=name,
        output_dir=output,
        match=match,
        include_sent=bool(raw.get("includeSent", True)),
        include_bin=bool(raw.get("includeBin", False)),
        extra=extra,
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
