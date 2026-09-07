#!/usr/bin/env python3
"""PyInstaller entry: run the MailExporter criteria engine (self-contained)."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# When not frozen, allow imports from the repo root
if not getattr(sys, "frozen", False):
    repo = Path(__file__).resolve().parents[2]
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))


def _cmd_serve(config_default: str | None) -> int:
    """
    Long-lived worker: one JSON request per stdin line, one JSON response per line.
    Request: {"cmd":"export","config":...,"jobId":...,"jobName":...,"dryRun":bool,...}
    """
    # Eager-import so the first real export isn't paying import cost.
    import engine.discover  # noqa: F401
    import engine.export  # noqa: F401

    from engine.cli import run_export

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
            config=req.get("config") or config_default,
            job_id=req.get("jobId"),
            job_name=req.get("jobName"),
            dry_run=bool(req.get("dryRun")),
            force_full=bool(req.get("forceFull")),
            bench=bool(req.get("bench")),
        )
        payload["exitCode"] = code
        print(json.dumps(payload), flush=True)
    return 0


def main() -> int:
    from engine.cli import (
        cmd_append_draft,
        cmd_list,
        cmd_seed,
        run_export,
    )

    argv = sys.argv[1:]
    config = None
    if "--config" in argv:
        i = argv.index("--config")
        if i + 1 < len(argv):
            config = argv[i + 1]
            del argv[i : i + 2]

    parser = argparse.ArgumentParser(prog="MailExporterEngine")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("seed")
    sub.add_parser("list")
    sub.add_parser("serve")
    sub.add_parser("mcp", help="Run local MailExporter MCP server (stdio)")
    p_ex = sub.add_parser("export")
    p_ex.add_argument("--job-id")
    p_ex.add_argument("--job-name")
    p_ex.add_argument("--dry-run", action="store_true")
    p_ex.add_argument("--force-full", action="store_true")
    p_ex.add_argument("--bench", action="store_true")
    p_ex.add_argument("--no-rg", action="store_true")
    p_ad = sub.add_parser("append-draft")
    p_ad.add_argument("markdown", nargs="+")
    ns = parser.parse_args(argv)
    ns.config = config

    if ns.cmd == "seed":
        return cmd_seed(ns)
    if ns.cmd == "list":
        return cmd_list(ns)
    if ns.cmd == "serve":
        return _cmd_serve(ns.config)
    if ns.cmd == "mcp":
        if ns.config:
            os.environ["MAILEXPORTER_CONFIG"] = ns.config
        from mailexporter_mcp import main as mcp_main
        mcp_main()
        return 0
    if ns.cmd == "append-draft":
        return cmd_append_draft(ns)

    if ns.cmd == "export":
        if getattr(ns, "no_rg", False):
            os.environ["MAILEXPORTER_NO_RG"] = "1"
        payload, code = run_export(
            config=ns.config,
            job_id=ns.job_id,
            job_name=ns.job_name,
            dry_run=ns.dry_run,
            force_full=ns.force_full,
            bench=ns.bench,
        )
        if payload.get("error") and not payload.get("results"):
            print(f"error: {payload['error']}", file=sys.stderr)
            return code or 1
        print(payload.get("line", ""))
        print(json.dumps(payload))
        return code

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
