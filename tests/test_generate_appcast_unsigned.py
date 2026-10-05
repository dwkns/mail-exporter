"""Unsigned Sparkle appcast has an enclosure and no EdDSA signature."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load():
    root = Path(__file__).resolve().parents[1]
    path = root / "scripts" / "generate-appcast-unsigned.py"
    spec = importlib.util.spec_from_file_location("generate_appcast_unsigned", path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def test_unsigned_appcast_has_enclosure_without_ed_signature(tmp_path: Path) -> None:
    zip_path = tmp_path / "MailExporter-macOS-arm64.zip"
    zip_path.write_bytes(b"fake-zip")
    xml = _load().build_appcast(
        zip_path=str(zip_path),
        version="v1.2.3",
        build="99",
        tag="v1.2.3",
        asset_name="MailExporter-macOS-arm64.zip",
    )
    assert "sparkle:edSignature" not in xml
    assert "<sparkle:version>99</sparkle:version>" in xml
    assert "<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>" in xml
    assert "releases/download/v1.2.3/MailExporter-macOS-arm64.zip" in xml
    assert 'length="8"' in xml
