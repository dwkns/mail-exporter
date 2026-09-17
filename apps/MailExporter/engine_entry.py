#!/usr/bin/env python3
"""PyInstaller entry: wrap engine.cli (self-contained)."""

from __future__ import annotations

import sys
from pathlib import Path

# When not frozen, allow imports from the repo root
if not getattr(sys, "frozen", False):
    repo = Path(__file__).resolve().parents[2]
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))


def main() -> int:
    from engine.cli import main as cli_main

    return cli_main()


if __name__ == "__main__":
    raise SystemExit(main())
