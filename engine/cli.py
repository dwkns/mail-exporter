"""Shared CLI for `python -m engine` and the bundled MailExporterEngine."""

from __future__ import annotations

import argparse
import json
import os
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


def _extract_flag_value(argv: list[str], flag: str) -> tuple[list[str], str | None]:
    out = list(argv)
    value = None
    if flag in out:
        i = out.index(flag)
        if i + 1 < len(out):
            value = out[i + 1]
            del out[i : i + 2]
    return out, value


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
    shared_candidates = None
    try:
        if len(selected) > 1:
            from engine.criteria import Clause, MatchGroup, MatchSpec, search_terms
            from engine.discover import candidate_paths

            term_lists = [search_terms(j.match) for j in selected]
            if all(term_lists):
                include_sent = any(j.include_sent for j in selected)
                include_bin = any(j.include_bin for j in selected)
                uniq = list(dict.fromkeys(t for ts in term_lists for t in ts))
                union = MatchSpec(
                    conjunction="any",
                    groups=[
                        MatchGroup(
                            conjunction="any",
                            clauses=[
                                Clause(field="entire", op="contains", values=uniq)
                            ],
                        )
                    ],
                )
                shared_candidates = candidate_paths(
                    union,
                    include_sent=include_sent,
                    include_bin=include_bin,
                )
        for job in selected:
            timings = {} if bench else None
            result = run_job(
                job,
                dry_run=dry_run,
                force_full=force_full,
                timings=timings,
                candidates=shared_candidates,
            )
            results.append(result)
            if not result.get("countMatch", True) and not dry_run:
                any_fail = True
    except MailAccessError as exc:
        return {"error": str(exc), "ok": False}, 1

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
    if getattr(args, "no_rg", False):
        os.environ["MAILEXPORTER_NO_RG"] = "1"
    payload, code = run_export(
        config=args.config,
        job_id=args.job_id,
        job_name=args.job_name,
        dry_run=args.dry_run,
        force_full=args.force_full,
        bench=bool(getattr(args, "bench", False)),
    )
    if payload.get("error") and not payload.get("results"):
        print(f"error: {payload['error']}", file=sys.stderr)
        return code or 1
    if not getattr(args, "json", False):
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


def cmd_serve(args: argparse.Namespace) -> int:
    """Long-lived worker: one JSON request per stdin line, one JSON response."""
    import engine.discover  # noqa: F401
    import engine.export  # noqa: F401

    print(json.dumps({"ready": True}), flush=True)
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        if line in ("quit", "exit"):
            print(json.dumps({"bye": True}), flush=True)
            return 0
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            print(json.dumps({"ok": False, "error": f"bad json: {exc}"}), flush=True)
            continue

        cmd = req.get("cmd")
        if cmd == "ping":
            print(json.dumps({"ok": True, "pong": True}), flush=True)
            continue
        if cmd != "export":
            print(json.dumps({"ok": False, "error": f"unknown cmd: {cmd}"}), flush=True)
            continue

        if req.get("noRg"):
            os.environ["MAILEXPORTER_NO_RG"] = "1"
        else:
            os.environ.pop("MAILEXPORTER_NO_RG", None)

        payload, code = run_export(
            config=req.get("config") or args.config,
            job_id=req.get("jobId"),
            job_name=req.get("jobName"),
            dry_run=bool(req.get("dryRun")),
            force_full=bool(req.get("forceFull")),
            bench=bool(req.get("bench")),
        )
        payload["exitCode"] = code
        print(json.dumps(payload), flush=True)
    return 0


def cmd_mcp(args: argparse.Namespace) -> int:
    if args.config:
        os.environ["MAILEXPORTER_CONFIG"] = str(config_path(args.config))
    from mailexporter_mcp import main as mcp_main

    mcp_main()
    return 0


def add_common_subcommands(sub: argparse._SubParsersAction) -> None:
    """Register seed / list / export / append-draft / serve / mcp."""
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
    p_ex.add_argument("--bench", action="store_true", help="Include timings (CLI only)")
    p_ex.add_argument("--no-rg", action="store_true", help="Disable ripgrep")
    p_ex.add_argument("--json", action="store_true", help="Print JSON only (no summary line)")
    p_ex.set_defaults(func=cmd_export)

    p_ad = sub.add_parser(
        "append-draft",
        aliases=["draft"],
        help="Open an Apple Mail draft from Markdown (never sends)",
    )
    p_ad.add_argument("markdown", nargs="+", help=".md file(s) with email front matter")
    p_ad.set_defaults(func=cmd_append_draft)

    p_serve = sub.add_parser("serve", help="Long-lived JSON worker (stdin/stdout)")
    p_serve.set_defaults(func=cmd_serve)

    p_mcp = sub.add_parser("mcp", help="Run local MailExporter MCP server (stdio)")
    p_mcp.set_defaults(func=cmd_mcp)


def build_parser() -> argparse.ArgumentParser:
    prog = "MailExporterEngine" if getattr(sys, "frozen", False) else "engine"
    parser = argparse.ArgumentParser(prog=prog, description="MailExporter engine")
    parser.add_argument(
        "--config",
        help="jobs.json path (default: app pointer / Application Support)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    add_common_subcommands(sub)
    return parser


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    raw, config = _extract_flag_value(raw, "--config")
    parser = build_parser()
    args = parser.parse_args(raw)
    if config:
        args.config = config
    elif not getattr(args, "config", None):
        args.config = None
    return args.func(args)
