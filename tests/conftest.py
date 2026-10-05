"""Shared fixtures for MailExporter engine tests (no Mail / network)."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Ensure repo root is importable when pytest is invoked from elsewhere.
_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


@pytest.fixture
def repo_root() -> Path:
    return _ROOT


@pytest.fixture(autouse=True)
def _isolate_last_export(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep MCP/CLI export status out of the real Application Support file."""
    monkeypatch.setenv("MAILEXPORTER_LAST_EXPORT", str(tmp_path / "last-export.json"))
