"""CLI: python -m engine …"""

from __future__ import annotations

import sys
from pathlib import Path

# Allow `python -m engine` from project root
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from engine.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
