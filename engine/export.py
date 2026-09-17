"""Export / dry-run matched messages to .eml files."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from .criteria import decode_mime_header, header_value, match_message, spec_needs_body
from .discover import candidate_paths
from .jobs import Job
from .mailio import (
    attachments_dir_for,
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
        return {"ids": [], "files": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("ids"), list):
            files = data.get("files") if isinstance(data.get("files"), dict) else {}
            data["files"] = {str(k): str(v) for k, v in files.items()}
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"ids": [], "files": {}}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = {
        "ids": list(state.get("ids") or []),
        "files": dict(state.get("files") or {}),
    }
    if "watermarkMtime" in state:
        out["watermarkMtime"] = state["watermarkMtime"]
    if "matchHash" in state:
        out["matchHash"] = state["matchHash"]
    path.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")


def prune_orphans(output_dir: Path, keep_ids: set[str], files: dict[str, str] | None = None) -> int:
    removed = 0
    known = files or {}
    remaining: dict[str, str] = {}
    seen_files: set[Path] = set()
    for mid, name in known.items():
        path = output_dir / name
        if mid not in keep_ids:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
            continue
        if path.is_file():
            remaining[mid] = name
            seen_files.add(path.resolve())
    for path in list(output_dir.glob("*.eml")):
        if path.resolve() in seen_files:
            continue
        mid = message_id_from_eml_file(path)
        if mid is None or mid not in keep_ids:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
        else:
            remaining[mid] = path.name
    if files is not None:
        files.clear()
        files.update(remaining)
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
    candidates: list[Path] | None = None,
    watermark_mtime: float | None = None,
) -> list[tuple[Path, bytes, int]]:
    """Return list of (path, msg_bytes, attachments_filled) for matching messages."""
    by_id: dict[str, tuple[Path, bytes, int]] = {}
    t0 = time.perf_counter()
    if candidates is None:
        mail_root = None
        raw_root = job.extra.get("mailRoot")
        if isinstance(raw_root, str) and raw_root.strip():
            mail_root = Path(raw_root).expanduser()
        candidates = candidate_paths(
            job.match,
            mail_root,
            include_sent=job.include_sent,
            include_bin=job.include_bin,
            timings=timings,
        )
    t_cand = time.perf_counter()
    if timings is not None:
        timings["candidates"] = len(candidates)
        timings["discover_s"] = round(t_cand - t0, 3)

    header_only = not spec_needs_body(job.match)
    max_bytes = 64_000 if header_only else None

    matched = 0
    load_s = 0.0
    match_s = 0.0
    attach_s = 0.0
    skipped_mtime = 0
    for path in candidates:
        if watermark_mtime is not None:
            try:
                if path.stat().st_mtime <= watermark_mtime:
                    skipped_mtime += 1
                    continue
            except OSError:
                continue
        t_l = time.perf_counter()
        try:
            raw = read_emlx_rfc822(path, max_bytes=max_bytes)
        except Exception:
            continue
        load_s += time.perf_counter() - t_l

        t_m = time.perf_counter()
        if not match_message(job.match, raw):
            match_s += time.perf_counter() - t_m
            continue
        match_s += time.perf_counter() - t_m
        matched += 1

        sid = message_stable_id(raw, path)
        if sid not in by_id:
            by_id[sid] = (path, raw, 0)

    if timings is not None:
        timings["matched"] = matched
        timings["load_raw_s"] = round(load_s, 3)
        timings["match_s"] = round(match_s, 3)
        timings["attach_s"] = round(attach_s, 3)
        timings["skipped_mtime"] = skipped_mtime
        timings["collect_total_s"] = round(time.perf_counter() - t0, 3)
        timings["header_only"] = header_only
    _collect_thread_parents(job, by_id)
    return list(by_id.values())


def short_label(name: str) -> str:
    parts = [p for p in str(name or "").split() if p]
    if not parts:
        return "Job"
    return " ".join(parts[:2])


def match_hash(job: Job) -> str:
    import hashlib

    blob = json.dumps(
        {
            "match": job.match.to_dict(),
            "includeThread": bool(job.include_thread),
            "includeSent": bool(job.include_sent),
            "includeBin": bool(job.include_bin),
        },
        sort_keys=True,
        default=str,
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def _referenced_message_ids(raw: bytes) -> set[str]:
    found: set[str] = set()
    for hdr in ("In-Reply-To", "References"):
        val = header_value(raw, hdr) or ""
        for tok in re.findall(r"<[^>]+>", val):
            found.add(tok.strip().lower())
        for tok in val.replace(",", " ").split():
            t = tok.strip().lower()
            if not t or t.startswith("<"):
                continue
            if "@" in t:
                found.add(f"<{t}>")
    return found


def _norm_mid(raw: str) -> str:
    s = (raw or "").strip().lower()
    if not s:
        return ""
    if not s.startswith("<"):
        s = "<" + s
    if not s.endswith(">"):
        s = s + ">"
    return s


def _collect_thread_parents(
    job: Job,
    by_id: dict[str, tuple[Path, bytes, int]],
) -> None:
    if not job.include_thread or not by_id:
        return
    have = {_norm_mid(message_stable_id(raw, path)) for path, raw, _ in by_id.values()}
    needed: set[str] = set()
    for _path, raw, _ in by_id.values():
        needed |= _referenced_message_ids(raw)
    missing = {mid for mid in needed if _norm_mid(mid) not in have}
    if not missing:
        return
    tokens = list(dict.fromkeys(mid.strip("<>") for mid in missing if mid.strip("<>")))
    if not tokens:
        return
    from engine.criteria import Clause, MatchGroup, MatchSpec

    spec = MatchSpec(
        conjunction="any",
        groups=[
            MatchGroup(
                conjunction="any",
                clauses=[Clause(field="entire", op="contains", values=tokens)],
            )
        ],
    )
    extra = candidate_paths(
        spec,
        include_sent=True,
        include_bin=job.include_bin,
    )
    seen_paths = {path.resolve() for path, _raw, _ in by_id.values()}
    want = {_norm_mid(mid) for mid in missing}
    for path in extra:
        try:
            if path.resolve() in seen_paths:
                continue
        except OSError:
            continue
        try:
            raw = read_emlx_rfc822(path, max_bytes=64_000)
        except Exception:
            continue
        sid = _norm_mid(message_stable_id(raw, path))
        if sid in want and sid not in by_id:
            by_id[sid] = (path, raw, 0)
            seen_paths.add(path.resolve())


def _sample_subjects(matches: list[tuple[Path, bytes, int]], limit: int = 5) -> list[str]:
    out: list[str] = []
    for _path, raw, _ in matches[:limit]:
        subj = decode_mime_header(header_value(raw, "Subject")) or "(no subject)"
        out.append(subj[:120])
    return out


def write_attachments_sidecar(output_dir: Path, stable_id: str, emlx_path: Path) -> int:
    att = attachments_dir_for(emlx_path)
    if att is None:
        return 0
    dest = output_dir / "Attachments" / short_id(stable_id)
    dest.mkdir(parents=True, exist_ok=True)
    written = 0
    for src in att.rglob("*"):
        if not src.is_file() or src.name.startswith("."):
            continue
        target = dest / src.name
        try:
            if not target.exists() or target.stat().st_size != src.stat().st_size:
                target.write_bytes(src.read_bytes())
            written += 1
        except OSError:
            continue
    return written


def promote_drafts_to_sent(output_dir: Path, matches: list[tuple[Path, bytes, int]]) -> int:
    drafts = output_dir / "Drafts"
    sent = output_dir / "Sent"
    if not drafts.is_dir():
        return 0
    sent.mkdir(exist_ok=True)
    ids: set[str] = set()
    subjects: set[str] = set()
    for _path, raw, _ in matches:
        mid = header_value(raw, "Message-ID") or header_value(raw, "Message-Id")
        if mid:
            ids.add(mid.strip().lower())
        subj = decode_mime_header(header_value(raw, "Subject")).strip().lower()
        if subj.startswith("re:"):
            subj = subj[3:].strip()
        if subj:
            subjects.add(subj)
    moved = 0
    for md in list(drafts.glob("*.md")):
        try:
            text = md.read_text(encoding="utf-8")
        except OSError:
            continue
        lower = text.lower()
        hit = False
        for mid in ids:
            token = mid.strip("<>")
            if token and token in lower:
                hit = True
                break
        if not hit:
            name_subj = md.stem.lower()
            if any(s and s in name_subj for s in subjects):
                hit = True
        if not hit:
            continue
        dest = sent / md.name
        try:
            md.replace(dest)
            moved += 1
        except OSError:
            continue
    return moved


def run_job(
    job: Job,
    *,
    dry_run: bool = False,
    force_full: bool = False,
    timings: dict | None = None,
    candidates: list[Path] | None = None,
) -> dict:
    output_dir = Path(job.output_dir).expanduser()
    state_file = output_dir / ".exported-ids.json"
    state = load_state(state_file) if not dry_run else {"ids": [], "files": {}}
    current_hash = match_hash(job)
    watermark = None
    if (
        not dry_run
        and not force_full
        and state.get("matchHash") == current_hash
        and isinstance(state.get("watermarkMtime"), (int, float))
    ):
        watermark = float(state["watermarkMtime"])

    matches = collect_matches(
        job,
        dry_run=dry_run,
        timings=timings,
        candidates=candidates,
        watermark_mtime=watermark,
    )
    match_count = len(matches)
    keep_ids = {message_stable_id(msg, path) for path, msg, _ in matches}
    samples = _sample_subjects(matches)

    if dry_run:
        result = {
            "id": job.id,
            "name": job.name,
            "dryRun": True,
            "matchCount": match_count,
            "newlyWritten": 0,
            "folderCount": match_count,
            "countMatch": True,
            "samples": samples,
            "line": f"{match_count} match" if match_count == 1 else f"{match_count} matches",
        }
        if timings is not None:
            result["timings"] = timings
        return result

    output_dir.mkdir(parents=True, exist_ok=True)
    from .howto import write_how_to

    write_how_to(output_dir, mailbox_name=job.name)

    files = dict(state.get("files") or {})
    if force_full:
        for path in output_dir.glob("*.eml"):
            try:
                path.unlink()
            except OSError:
                pass
        state = {"ids": [], "files": {}}
        files = {}
        save_state(state_file, state)

    if watermark is None:
        orphans = prune_orphans(output_dir, keep_ids, files)
    else:
        orphans = 0
        keep_ids = keep_ids | set(files)
    exported = set(files) | set(state.get("ids") or [])
    newly_written = 0
    attachments_filled = 0
    sidecar_written = 0
    errors = 0
    t_attach = 0.0
    newest_mtime = watermark or 0.0

    for path, raw_bytes, _ in matches:
        try:
            newest_mtime = max(newest_mtime, path.stat().st_mtime)
        except OSError:
            pass
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
        old_name = files.get(sid)
        if old_name:
            try:
                (output_dir / old_name).unlink()
            except OSError:
                pass
        else:
            remove_existing_for_id(output_dir, sid)
        try:
            out_path.write_bytes(msg_bytes)
        except OSError:
            errors += 1
            continue
        files[sid] = filename
        exported.add(sid)
        newly_written += 1
        attachments_filled += filled
        sidecar_written += write_attachments_sidecar(output_dir, sid, path)

    promoted = promote_drafts_to_sent(output_dir, matches)
    folder_count = len(list(output_dir.glob("*.eml")))
    state = {
        "ids": sorted(files),
        "files": files,
        "watermarkMtime": newest_mtime,
        "matchHash": current_hash,
    }
    save_state(state_file, state)
    if timings is not None:
        timings["attach_write_s"] = round(t_attach, 3)
        timings["newly_written"] = newly_written
    count_ok = folder_count == match_count or watermark is not None
    if newly_written == 0:
        line = "Up to date"
    else:
        line = f"{newly_written} new" if newly_written != 1 else "1 new"
    return {
        "id": job.id,
        "name": job.name,
        "outputDir": str(output_dir),
        "dryRun": False,
        "matchCount": match_count,
        "newlyWritten": newly_written,
        "attachmentsFilled": attachments_filled,
        "attachmentsSidecar": sidecar_written,
        "orphansRemoved": orphans,
        "draftsPromoted": promoted,
        "folderCount": folder_count,
        "countMatch": count_ok,
        "errors": errors,
        "samples": samples,
        "line": line,
    }
