"""Export / dry-run matched messages to .eml files."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from .criteria import decode_mime_header, header_value, match_message
from .discover import candidate_paths
from .jobs import Job
from .mailio import (
    load_message_bytes,
    message_stable_id,
    message_timestamp,
    read_emlx_rfc822,
    sanitize_subject,
    short_id,
)


def message_id_from_eml_file(path: Path) -> str | None:
    try:
        msg_bytes = path.read_bytes()
    except OSError:
        return None
    if not msg_bytes.strip():
        return None
    mid = header_value(msg_bytes, "Message-ID") or header_value(msg_bytes, "Message-Id")
    if mid and mid.strip():
        return mid.strip()
    return f"eml-file:{path.name}"


def load_state(path: Path) -> dict:
    if not path.is_file():
        return {"ids": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("ids"), list):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"ids": []}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def prune_orphans(output_dir: Path, keep_ids: set[str]) -> int:
    removed = 0
    for path in list(output_dir.glob("*.eml")):
        mid = message_id_from_eml_file(path)
        if mid is None or mid not in keep_ids:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def remove_existing_for_id(output_dir: Path, stable_id: str) -> None:
    target = stable_id.strip()
    for path in list(output_dir.glob("*.eml")):
        mid = message_id_from_eml_file(path)
        if mid and mid.strip() == target:
            try:
                path.unlink()
            except OSError:
                pass


def collect_matches(
    job: Job,
    *,
    dry_run: bool = False,
    timings: dict | None = None,
) -> list[tuple[Path, bytes, int]]:
    """Return list of (path, msg_bytes, attachments_filled) for matching messages."""
    by_id: dict[str, tuple[Path, bytes, int]] = {}
    t0 = time.perf_counter()
    candidates = candidate_paths(
        job.match,
        include_sent=job.include_sent,
        include_bin=job.include_bin,
        timings=timings,
    )
    t_cand = time.perf_counter()
    if timings is not None:
        timings["candidates"] = len(candidates)
        timings["discover_s"] = round(t_cand - t0, 3)

    matched = 0
    load_s = 0.0
    match_s = 0.0
    attach_s = 0.0
    for path in candidates:
        t_l = time.perf_counter()
        try:
            # Fast path: evaluate criteria on the on-disk .emlx before any
            # attachment reassembly (MIME parse is expensive).
            raw = read_emlx_rfc822(path)
        except Exception:
            continue
        load_s += time.perf_counter() - t_l

        t_m = time.perf_counter()
        if not match_message(job.match, raw):
            match_s += time.perf_counter() - t_m
            continue
        match_s += time.perf_counter() - t_m
        matched += 1

        # Prefer raw message for matching; only reassemble attachments when
        # we actually need to write .eml (done in run_job for new copies).
        if dry_run:
            sid = message_stable_id(raw, path)
            if sid not in by_id:
                by_id[sid] = (path, raw, 0)
            continue

        sid = message_stable_id(raw, path)
        if sid not in by_id:
            by_id[sid] = (path, raw, 0)

    if timings is not None:
        timings["matched"] = matched
        timings["load_raw_s"] = round(load_s, 3)
        timings["match_s"] = round(match_s, 3)
        timings["attach_s"] = round(attach_s, 3)
        timings["collect_total_s"] = round(time.perf_counter() - t0, 3)
    return list(by_id.values())


def short_label(name: str) -> str:
    parts = [p for p in str(name or "").split() if p]
    if not parts:
        return "Job"
    return " ".join(parts[:2])


def run_job(
    job: Job,
    *,
    dry_run: bool = False,
    force_full: bool = False,
    timings: dict | None = None,
) -> dict:
    matches = collect_matches(job, dry_run=dry_run, timings=timings)
    match_count = len(matches)
    keep_ids = {message_stable_id(msg, path) for path, msg, _ in matches}

    if dry_run:
        result = {
            "id": job.id,
            "name": job.name,
            "dryRun": True,
            "matchCount": match_count,
            "newlyWritten": 0,
            "folderCount": match_count,
            "countMatch": True,
            "line": f"{short_label(job.name)}: {match_count} match",
        }
        if timings is not None:
            result["timings"] = timings
        return result

    output_dir = Path(job.output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    from .howto import write_how_to

    write_how_to(output_dir, mailbox_name=job.name)
    state_file = output_dir / ".exported-ids.json"

    if force_full:
        for path in output_dir.glob("*.eml"):
            try:
                path.unlink()
            except OSError:
                pass
        state = {"ids": []}
        save_state(state_file, state)
    else:
        state = load_state(state_file)

    orphans = prune_orphans(output_dir, keep_ids)
    # Reconcile state to disk after prune
    disk_ids = set()
    for path in output_dir.glob("*.eml"):
        mid = message_id_from_eml_file(path)
        if mid:
            disk_ids.add(mid)
    state = {"ids": sorted(disk_ids)}
    save_state(state_file, state)
    exported = set(state["ids"])

    newly_written = 0
    attachments_filled = 0
    errors = 0
    t_attach = 0.0

    for path, raw_bytes, _ in matches:
        sid = message_stable_id(raw_bytes, path)
        if sid in exported and not force_full:
            continue
        t_a = time.perf_counter()
        try:
            msg_bytes, filled = load_message_bytes(path, raw=raw_bytes)
        except Exception:
            msg_bytes, filled = raw_bytes, 0
        t_attach += time.perf_counter() - t_a
        subject = decode_mime_header(header_value(msg_bytes, "Subject"))
        ts = message_timestamp(msg_bytes, path)
        filename = (
            f"{ts.strftime('%Y-%m-%d_%H%M%S')}_"
            f"{sanitize_subject(subject)}_"
            f"{short_id(sid)}.eml"
        )
        out_path = output_dir / filename
        remove_existing_for_id(output_dir, sid)
        try:
            out_path.write_bytes(msg_bytes)
        except OSError:
            errors += 1
            continue
        if sid not in exported:
            state["ids"].append(sid)
            exported.add(sid)
        newly_written += 1
        attachments_filled += filled

    save_state(state_file, state)
    if timings is not None:
        timings["attach_write_s"] = round(t_attach, 3)
        timings["newly_written"] = newly_written

    # Final disk count
    folder_count = len(list(output_dir.glob("*.eml")))
    count_ok = folder_count == match_count
    line = f"{short_label(job.name)}: {newly_written} copied"
    return {
        "id": job.id,
        "name": job.name,
        "outputDir": str(output_dir),
        "dryRun": False,
        "matchCount": match_count,
        "newlyWritten": newly_written,
        "attachmentsFilled": attachments_filled,
        "orphansRemoved": orphans,
        "folderCount": folder_count,
        "countMatch": count_ok,
        "errors": errors,
        "line": line,
    }
