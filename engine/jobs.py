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
    "projectDir",
    "match",
    "includeSent",
    "includeBin",
    "includeThread",
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
    include_thread: bool = False
    project_dir: str = ""
    extra: dict[str, Any] = field(default_factory=dict)
    # Set when this saved job's match cannot be used. Other jobs still load.
    error: str = ""
    # Original job object. A later save must not replace a bad match with an empty one.
    source: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        if self.error and self.source is not None:
            return dict(self.source)
        data: dict[str, Any] = {
            "id": self.id,
            "name": self.name,
            "outputDir": self.output_dir,
            "includeSent": self.include_sent,
            "includeBin": self.include_bin,
            "includeThread": self.include_thread,
            "match": self.match.to_dict(),
        }
        if self.project_dir:
            data["projectDir"] = self.project_dir
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


def parse_job(
    raw: dict[str, Any],
    *,
    require_output_dir: bool = True,
    strict_match: bool = False,
) -> Job:
    jid = str(raw.get("id") or uuid.uuid4())
    name = str(raw.get("name") or "").strip() or "Untitled"
    output = str(raw.get("outputDir") or "").strip()
    if not output and require_output_dir:
        raise ValueError(f"job {name!r}: outputDir required")
    match = parse_match(
        raw.get("match") if isinstance(raw.get("match"), dict) else None,
        strict=strict_match,
    )
    extra = {k: v for k, v in raw.items() if k not in _KNOWN_JOB_KEYS}
    return Job(
        id=jid,
        name=name,
        output_dir=output,
        match=match,
        include_sent=bool(raw.get("includeSent", True)),
        include_bin=bool(raw.get("includeBin", False)),
        include_thread=bool(raw.get("includeThread", False)),
        project_dir=str(raw.get("projectDir") or "").strip(),
        extra=extra,
    )


def _job_error(raw: dict[str, Any], path: Path, detail: str) -> str:
    name = str(raw.get("name") or "").strip() or "Untitled"
    jid = str(raw.get("id") or "").strip() or "(no id)"
    return f"{name} ({jid}): {path}: {detail}"


def _invalid_job(raw: dict[str, Any], path: Path, exc: ValueError) -> Job:
    """Keep a saved job that has a bad match. Do not drop the other jobs."""
    name = str(raw.get("name") or "").strip() or "Untitled"
    jid = str(raw.get("id") or "").strip() or str(uuid.uuid4())
    extra = {k: v for k, v in raw.items() if k not in _KNOWN_JOB_KEYS}
    return Job(
        id=jid,
        name=name,
        output_dir=str(raw.get("outputDir") or "").strip(),
        match=MatchSpec(conjunction="all", groups=[]),
        include_sent=bool(raw.get("includeSent", True)),
        include_bin=bool(raw.get("includeBin", False)),
        include_thread=bool(raw.get("includeThread", False)),
        project_dir=str(raw.get("projectDir") or "").strip(),
        extra=extra,
        error=_job_error(raw, path, str(exc)),
        source=dict(raw),
    )


def load_jobs(path: Path, *, require_output_dir: bool = True) -> JobsFile:
    if not path.is_file():
        return JobsFile(jobs=[])
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("jobs file root must be an object")
    raw_jobs = data.get("jobs") or []
    if not isinstance(raw_jobs, list):
        raise ValueError("jobs must be an array")
    jobs: list[Job] = []
    for raw in raw_jobs:
        if not isinstance(raw, dict):
            continue
        name = str(raw.get("name") or "").strip() or "Untitled"
        output = str(raw.get("outputDir") or "").strip()
        if require_output_dir and not output:
            raise ValueError(f"job {name!r}: outputDir required")
        try:
            jobs.append(
                parse_job(
                    raw,
                    require_output_dir=False,
                    strict_match=bool(output),
                )
            )
        except ValueError as exc:
            jobs.append(_invalid_job(raw, path, exc))
    return JobsFile(jobs=jobs)


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


def output_dir_error(raw: str) -> str | None:
    """Refuse the disk root and any folder inside Apple Mail."""
    text = (raw or "").strip()
    if not text:
        return "output_dir required"
    try:
        path = Path(text).expanduser().resolve()
    except OSError:
        path = Path(text).expanduser()
    if path == Path("/"):
        return "That folder can’t be used."
    mail = (Path.home() / "Library" / "Mail").resolve()
    if path == mail or mail in path.parents:
        return "That folder is inside Apple Mail. Choose a different folder."
    return None


def _opt_bool(raw: Any, current: bool) -> bool:
    if isinstance(raw, bool):
        return raw
    if raw is None:
        return current
    text = str(raw).strip().lower()
    if not text:
        return current
    if text in ("1", "true", "yes"):
        return True
    if text in ("0", "false", "no"):
        return False
    return current


def _job_public(job: Job) -> dict[str, Any]:
    row = job.to_dict()
    row.pop("match", None)
    return row


def apply_job_command(req: dict[str, Any], config: Path) -> dict[str, Any]:
    """Create or change a job. Callers outside the app must ask the app to run this."""
    cmd = str(req.get("cmd") or "")
    if cmd == "create-job":
        return _create_job(req, config)
    if cmd == "edit-job":
        return _edit_job(req, config)
    return {"ok": False, "error": f"unknown cmd: {cmd}"}


def _create_job(req: dict[str, Any], config: Path) -> dict[str, Any]:
    from engine.howto import write_how_to
    from engine.project import resolved_project_root

    name = str(req.get("name") or "").strip()
    output_dir = str(req.get("outputDir") or "").strip()
    if not name:
        return {"ok": False, "error": "name required"}
    folder_error = output_dir_error(output_dir)
    if folder_error:
        return {"ok": False, "error": folder_error}
    raw_match = req.get("match")
    if raw_match is None:
        raw_match = {
            "conjunction": "any",
            "conditions": [
                {"field": "entire", "op": "contains", "values": [name]}
            ],
        }
    if not isinstance(raw_match, dict):
        return {"ok": False, "error": "match must be an object"}
    try:
        match = parse_match(raw_match, strict=True)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    jobs = load_jobs(config)
    if any(j.name.lower() == name.lower() for j in jobs.jobs):
        return {"ok": False, "error": f"job already exists: {name}"}
    job = Job(
        id=str(uuid.uuid4()),
        name=name,
        output_dir=output_dir,
        match=match,
        include_sent=_opt_bool(req.get("includeSent", True), True),
        include_bin=_opt_bool(req.get("includeBin", False), False),
        include_thread=_opt_bool(req.get("includeThread", False), False),
        project_dir=str(resolved_project_root(output_dir)),
    )
    jobs.jobs.append(job)
    save_jobs(jobs, config)
    try:
        write_how_to(Path(output_dir), mailbox_name=name)
    except Exception:
        pass
    return {"ok": True, "job": _job_public(job), "config": str(config)}


def _edit_job(req: dict[str, Any], config: Path) -> dict[str, Any]:
    from engine.project import resolved_project_root

    job_id = str(req.get("jobId") or "").strip()
    job_name = str(req.get("jobName") or "").strip()
    jobs = load_jobs(config)
    target = None
    if job_id:
        for job in jobs.jobs:
            if job.id == job_id:
                target = job
                break
        if target is None:
            return {"ok": False, "error": f"job id not found: {job_id}"}
    elif job_name:
        needle = job_name.lower()
        for job in jobs.jobs:
            if job.name.lower() == needle:
                target = job
                break
        if target is None:
            return {"ok": False, "error": f"job name not found: {job_name}"}
    else:
        return {"ok": False, "error": "provide job_id or job_name"}
    assert target is not None
    new_name = str(req.get("name") or "").strip()
    if new_name:
        target.name = new_name
    new_dir = str(req.get("outputDir") or "").strip()
    if new_dir:
        folder_error = output_dir_error(new_dir)
        if folder_error:
            return {"ok": False, "error": folder_error}
        target.output_dir = new_dir
        target.project_dir = str(resolved_project_root(target.output_dir))
    raw_match = req.get("match")
    if isinstance(raw_match, dict):
        try:
            target.match = parse_match(raw_match, strict=True)
        except Exception as exc:
            return {"ok": False, "error": str(exc)}
        target.error = ""
        target.source = None
    target.include_sent = _opt_bool(req.get("includeSent"), target.include_sent)
    target.include_bin = _opt_bool(req.get("includeBin"), target.include_bin)
    target.include_thread = _opt_bool(req.get("includeThread"), target.include_thread)
    if target.error and target.source is not None:
        target.source["name"] = target.name
        target.source["outputDir"] = target.output_dir
        target.source["includeSent"] = target.include_sent
        target.source["includeBin"] = target.include_bin
        target.source["includeThread"] = target.include_thread
        if target.project_dir:
            target.source["projectDir"] = target.project_dir
    save_jobs(jobs, config)
    return {"ok": True, "job": _job_public(target), "config": str(config)}
