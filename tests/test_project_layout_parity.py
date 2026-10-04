"""Keep Swift ProjectLayout, engine.project, and shared/project_layout.json aligned."""

from __future__ import annotations

import json
import re
from pathlib import Path

import engine.project as project

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "shared" / "project_layout.json"
ENGINE_COPY = ROOT / "engine" / "project_layout.json"
SWIFT = ROOT / "apps" / "MailExporter" / "Sources" / "ProjectLayout.swift"


def _load_shared() -> dict:
    return json.loads(SHARED.read_text(encoding="utf-8"))


def test_shared_layout_matches_engine_copy() -> None:
    assert SHARED.is_file()
    assert ENGINE_COPY.is_file()
    assert SHARED.read_text(encoding="utf-8") == ENGINE_COPY.read_text(encoding="utf-8")


def test_python_constants_match_shared() -> None:
    layout = _load_shared()
    assert project.EMAIL_DIR == layout["email_dir"]
    assert project.DOCUMENTS_DIR == layout["documents_dir"]
    assert project.NOTES_DIR == layout["notes_dir"]
    assert project.ARCHIVE_DIR == layout["archive_dir"]
    assert project.STATUS_FILENAME == layout["status_filename"]
    assert project.HOWTO_FILENAME == layout["howto_filename"]
    assert project.LEGACY_HOWTO == layout["legacy_howto_filename"]
    assert list(project.default_parent().relative_to(Path.home()).parts) == layout[
        "default_parent_segments"
    ]


def test_swift_project_layout_matches_shared() -> None:
    layout = _load_shared()
    text = SWIFT.read_text(encoding="utf-8")

    def swift_string(name: str) -> str:
        match = re.search(rf'static let {name} = "([^"]+)"', text)
        assert match, f"missing static let {name} in ProjectLayout.swift"
        return match.group(1)

    assert swift_string("emailDir") == layout["email_dir"]
    assert swift_string("documentsDir") == layout["documents_dir"]
    assert swift_string("notesDir") == layout["notes_dir"]
    assert swift_string("archiveDir") == layout["archive_dir"]
    assert swift_string("statusFile") == layout["status_filename"]
    assert swift_string("howToFile") == layout["howto_filename"]
    assert swift_string("legacyHowToFile") == layout["legacy_howto_filename"]

    parent = "/".join(layout["default_parent_segments"])
    assert f'appendingPathComponent("{parent}")' in text
    assert "Desktop/home" not in text
    assert "func resolvedProjectRoot" in text
