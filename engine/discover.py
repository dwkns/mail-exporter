"""Discover candidate .emlx paths (bundled rg when available, else Python scan)."""

from __future__ import annotations

import os
import re
import sys
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from .criteria import MatchSpec, search_terms
from .mailio import FDA_HELP, MailAccessError, find_mail_root, prefer_full_emlx, should_skip_path

# Cap concurrent file reads in the Python fallback path.
_PYTHON_SCAN_WORKERS = max(4, min(32, (os.cpu_count() or 4) * 2))

# Short-lived candidate cache so Check Matches / Export in the same session
# don't re-ripgrep ~70k files repeatedly.
_CANDIDATE_CACHE: dict[tuple, tuple[float, list[Path]]] = {}
_CANDIDATE_CACHE_TTL_S = 45.0

_RG_PATH: str | None | bool = False  # False = unset; None = missing; str = path


def _bundled_rg_candidates() -> list[Path]:
    """Paths where the app ships its own ripgrep (no Homebrew / PATH)."""
    out: list[Path] = []
    env = os.environ.get("MAILEXPORTER_RG", "").strip()
    if env:
        out.append(Path(env))

    # Frozen engine: …/Contents/Resources/MailExporterEngine/MailExporterEngine
    # Bundled rg:     …/Contents/Resources/bin/rg
    exe = Path(sys.executable).resolve()
    out.append(exe.parent / "bin" / "rg")
    out.append(exe.parent.parent / "bin" / "rg")

    # Dev: repo apps/MailExporter/vendor/rg/rg next to engine_entry
    here = Path(__file__).resolve()
    out.append(here.parents[1] / "apps" / "MailExporter" / "vendor" / "rg" / "rg")
    return out


def find_rg() -> str | None:
    """Return absolute path to bundled (or env-overridden) rg, or None."""
    global _RG_PATH
    if os.environ.get("MAILEXPORTER_NO_RG", "").strip() in ("1", "true", "yes"):
        return None
    if _RG_PATH is not False:
        return _RG_PATH if isinstance(_RG_PATH, str) else None

    found: str | None = None
    for path in _bundled_rg_candidates():
        if not path.is_file() or not os.access(path, os.X_OK):
            continue
        try:
            subprocess.run(
                [str(path), "--version"],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            found = str(path)
            break
        except (OSError, subprocess.CalledProcessError):
            continue

    _RG_PATH = found
    return found


def _permission_error(text: str) -> bool:
    t = text.lower()
    return "operation not permitted" in t or "permission denied" in t


def _compile_terms_bytes(terms: list[str]) -> re.Pattern[bytes] | None:
    if not terms:
        return None
    return re.compile(b"|".join(re.escape(t.encode("utf-8")) for t in terms), re.I)


def _file_matches_terms(path: Path, regex: re.Pattern[bytes] | None) -> Path | None:
    if regex is None:
        return path
    try:
        data = path.read_bytes()
    except PermissionError:
        raise
    except OSError:
        return None
    if regex.search(data):
        return path
    return None


def candidate_paths_via_python(
    mail_root: Path,
    terms: list[str],
    *,
    include_sent: bool = True,
    include_bin: bool = False,
    timings: dict | None = None,
) -> list[Path]:
    """Walk .emlx files in-process (needs Full Disk Access on this process)."""
    t0 = time.perf_counter()
    try:
        next(mail_root.iterdir())
    except PermissionError as exc:
        raise MailAccessError(f"{exc}\n\n{FDA_HELP}") from exc
    except StopIteration:
        pass

    regex = _compile_terms_bytes(terms)
    # Collect paths first (metadata only) — skip filters without reading bodies.
    to_scan: list[Path] = []
    try:
        for dirpath, dirnames, filenames in os.walk(mail_root):
            # Prune obvious junk dirs early
            dirnames[:] = [
                d
                for d in dirnames
                if d
                not in (
                    "Attachments",
                    "SmartMailboxes",
                    "MailData",
                    "Metadata Bundle",
                )
            ]
            for name in filenames:
                if not name.endswith(".emlx"):
                    continue
                path = Path(dirpath) / name
                if should_skip_path(
                    str(path), include_sent=include_sent, include_bin=include_bin
                ):
                    continue
                to_scan.append(path)
    except PermissionError as exc:
        raise MailAccessError(f"{exc}\n\n{FDA_HELP}") from exc

    t_walk = time.perf_counter()
    if timings is not None:
        timings["python_walk_s"] = round(t_walk - t0, 3)
        timings["python_files_seen"] = len(to_scan)

    if not to_scan:
        return []

    paths: list[Path] = []
    if regex is None:
        paths = to_scan
    else:
        # Parallel byte scans — dominant cost on large mailboxes.
        try:
            with ThreadPoolExecutor(max_workers=_PYTHON_SCAN_WORKERS) as pool:
                futs = [pool.submit(_file_matches_terms, p, regex) for p in to_scan]
                for fut in as_completed(futs):
                    try:
                        hit = fut.result()
                    except PermissionError as exc:
                        raise MailAccessError(f"{exc}\n\n{FDA_HELP}") from exc
                    if hit is not None:
                        paths.append(hit)
        except PermissionError as exc:
            raise MailAccessError(f"{exc}\n\n{FDA_HELP}") from exc

    t_scan = time.perf_counter()
    if timings is not None:
        timings["python_scan_s"] = round(t_scan - t_walk, 3)
        timings["python_hits"] = len(paths)

    return prefer_full_emlx(sorted({p.resolve() for p in paths}))


def candidate_paths_via_rg(
    mail_root: Path,
    terms: list[str],
    *,
    include_sent: bool = True,
    include_bin: bool = False,
    timings: dict | None = None,
) -> list[Path] | None:
    """
    Returns paths on success, or None if rg is unavailable / not permitted
    (caller should fall back to Python).
    """
    if not terms:
        return None
    rg = find_rg()
    if rg is None:
        if timings is not None:
            timings["rg"] = "disabled_or_missing"
        return None

    t0 = time.perf_counter()
    pattern = "|".join(re.escape(t) for t in terms)
    # --mmap + threads: ripgrep defaults are already fast; keep glob tight.
    proc = subprocess.run(
        [
            rg,
            "-l",
            "-i",
            "--mmap",
            "-j",
            str(_PYTHON_SCAN_WORKERS),
            pattern,
            str(mail_root),
            "--glob",
            "*.emlx",
            "--glob",
            "!**/Attachments/**",
        ],
        capture_output=True,
        text=True,
    )
    if timings is not None:
        timings["rg_bin"] = rg
    err = (proc.stderr or "").strip()
    if timings is not None:
        timings["rg_s"] = round(time.perf_counter() - t0, 3)
        timings["rg_returncode"] = proc.returncode
    if proc.returncode not in (0, 1):
        if _permission_error(err):
            if timings is not None:
                timings["rg"] = "permission_denied"
            return None
        raise RuntimeError(f"rg failed: {err or proc.returncode}")
    paths = [Path(line) for line in proc.stdout.splitlines() if line.strip()]
    filtered = prefer_full_emlx(
        sorted(
            {
                p.resolve()
                for p in paths
                if not should_skip_path(
                    str(p), include_sent=include_sent, include_bin=include_bin
                )
            }
        )
    )
    if timings is not None:
        timings["rg"] = "ok"
        timings["rg_hits"] = len(filtered)
    return filtered


def candidate_paths(
    spec: MatchSpec,
    mail_root: Path | None = None,
    *,
    include_sent: bool = True,
    include_bin: bool = False,
    timings: dict | None = None,
) -> list[Path]:
    root = mail_root or find_mail_root()
    terms = search_terms(spec)
    if timings is not None:
        timings["mail_root"] = str(root)
        timings["search_terms"] = len(terms)

    cache_key = (
        str(root),
        tuple(sorted(terms)),
        include_sent,
        include_bin,
        os.environ.get("MAILEXPORTER_NO_RG", ""),
    )
    now = time.perf_counter()
    hit = _CANDIDATE_CACHE.get(cache_key)
    if hit is not None:
        cached_at, cached_paths = hit
        if now - cached_at <= _CANDIDATE_CACHE_TTL_S:
            if timings is not None:
                timings["cache"] = "hit"
                timings["candidates"] = len(cached_paths)
                timings["discover_s"] = 0.0
            return list(cached_paths)

    via_rg = candidate_paths_via_rg(
        root,
        terms,
        include_sent=include_sent,
        include_bin=include_bin,
        timings=timings,
    )
    if via_rg is not None:
        paths = via_rg
    else:
        paths = candidate_paths_via_python(
            root,
            terms,
            include_sent=include_sent,
            include_bin=include_bin,
            timings=timings,
        )
    _CANDIDATE_CACHE[cache_key] = (now, paths)
    if timings is not None:
        timings["cache"] = "miss"
    return list(paths)
