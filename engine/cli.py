"""Shared CLI handlers for `python -m engine` and the bundled MailExporterEngine."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from engine.compose_draft import compose_draft
from engine.export import run_job
from engine.jobs import (
    default_jobs_path,
    load_jobs,
    save_jobs,
    seed_dhl_job,
    seed_sample_job,
)
from engine.mailio import MailAccessError


def config_path(config: str | None) -> Path:
    return Path(config).expanduser() if config else default_jobs_path()


def cmd_seed(args: argparse.Namespace) -> int:
    path = config_path(args.config)
    jobs = load_jobs(path)
    if not any(j.name.lower() in ("receipts", "sample") for j in jobs.jobs):
        jobs.jobs.insert(0, seed_sample_job())
    if not any(j.name.lower() in ("shipping", "dhl") for j in jobs.jobs):
        jobs.jobs.append(seed_dhl_job())
    save_jobs(jobs, path)
    print(f"Seeded jobs → {path}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    path = config_path(args.config)
    print(json.dumps(load_jobs(path).to_dict(), indent=2))
    return 0


def run_export(
    *,
    config: str | None,
    job_id: str | None,
    job_name: str | None,
    dry_run: bool,
    force_full: bool,
    bench: bool = False,
) -> tuple[dict, int]:
    """Run one or more export jobs. Returns (payload, exit_code)."""
    path = config_path(config)
    jobs = load_jobs(path)
    if not jobs.jobs:
        return {
            "error": "no jobs — run seed or create jobs in MailExporter",
            "ok": False,
        }, 1

    selected = jobs.jobs
    if job_id:
        selected = [j for j in jobs.jobs if j.id == job_id]
        if not selected:
            return {"error": f"job id not found: {job_id}", "ok": False}, 1
    elif job_name:
        needle = job_name.lower()
        selected = [j for j in jobs.jobs if j.name.lower() == needle]
        if not selected:
            return {"error": f"job name not found: {job_name}", "ok": False}, 1

    results = []
    any_fail = False
    t0 = time.perf_counter()
    try:
        for job in selected:
            timings = {} if bench else None
            result = run_job(
                job,
                dry_run=dry_run,
                force_full=force_full,
                timings=timings,
            )
            results.append(result)
            if not result.get("countMatch", True) and not dry_run:
                any_fail = True
    except MailAccessError as exc:
        return {"error": str(exc), "ok": False}, 1

    if not dry_run:
        save_jobs(jobs, path)

    line = " — ".join(r.get("line", "") for r in results)
    payload: dict = {
        "results": results,
        "line": line,
        "ok": not any_fail,
    }
    if bench:
        payload["wall_s"] = round(time.perf_counter() - t0, 3)
    return payload, (2 if any_fail else 0)


def cmd_export(args: argparse.Namespace) -> int:
    payload, code = run_export(
        config=args.config,
        job_id=args.job_id,
        job_name=args.job_name,
        dry_run=args.dry_run,
        force_full=args.force_full,
        bench=False,
    )
    if payload.get("error") and not payload.get("results"):
        print(f"error: {payload['error']}", file=sys.stderr)
        return code or 1
    print(payload.get("line", ""))
    print(json.dumps(payload))
    return code


def cmd_append_draft(args: argparse.Namespace) -> int:
    results = []
    any_fail = False
    for raw in args.markdown:
        out = compose_draft(Path(raw).expanduser())
        results.append(out)
        if not out.get("ok"):
            any_fail = True
    print(json.dumps({"results": results, "ok": not any_fail}, indent=2))
    return 1 if any_fail else 0


def add_common_subcommands(sub: argparse._SubParsersAction) -> None:
    """Register seed / list / export / append-draft on a subparsers object."""
    p_seed = sub.add_parser("seed", help="Add example jobs")
    p_seed.set_defaults(func=cmd_seed)

    p_list = sub.add_parser("list", help="Print jobs.json")
    p_list.set_defaults(func=cmd_list)

    p_ex = sub.add_parser("export", help="Export jobs")
    p_ex.add_argument("--job-id", help="Export a single job by id")
    p_ex.add_argument("--job-name", help="Export a single job by name")
    p_ex.add_argument("--dry-run", action="store_true", help="Count matches only")
    p_ex.add_argument(
        "--force-full", action="store_true", help="Wipe output .eml and re-export"
    )
    p_ex.set_defaults(func=cmd_export)

    p_ad = sub.add_parser(
        "append-draft",
        help="Compose a Mail draft via AppleScript (Make Mail Draft)",
    )
    p_ad.add_argument("markdown", nargs="+", help=".md file(s) with email front matter")
    p_ad.set_defaults(func=cmd_append_draft)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="engine", description="MailExporter engine")
    parser.add_argument(
        "--config",
        help="jobs.json path (default: ~/Library/Application Support/MailExporter/jobs.json)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    add_common_subcommands(sub)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)
