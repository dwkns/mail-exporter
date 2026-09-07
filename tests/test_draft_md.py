"""draft_md: front matter, attachments, message-id normalize."""

from __future__ import annotations

from pathlib import Path

import pytest

from engine.draft_md import (
    normalize_message_id,
    parse_markdown_draft,
    resolve_attachments,
)


FENCED = """\
---
To: alice@example.com, bob@example.com
Cc: carol@example.com
Bcc: secret@example.com
Subject: Quote follow-up
From: me@example.com
In-Reply-To: mid@example.com
Reply: reply-all
Attach: docs/a.pdf
Format: markdown
---

Hello **there**.
"""


def test_parse_fenced_front_matter() -> None:
    spec = parse_markdown_draft(FENCED)
    assert spec.to == ["alice@example.com", "bob@example.com"]
    assert spec.cc == ["carol@example.com"]
    assert spec.bcc == ["secret@example.com"]
    assert spec.subject == "Quote follow-up"
    assert spec.from_addr == "me@example.com"
    assert spec.in_reply_to == "mid@example.com"
    assert spec.reply_mode == "reply-all"
    assert spec.format == "markdown"
    assert spec.attach == ["docs/a.pdf"]
    assert "Hello **there**." in spec.body


def test_parse_legacy_headers_until_blank() -> None:
    text = (
        "To: a@b.com\n"
        "Subject: Hi\n"
        "\n"
        "Body line\n"
    )
    spec = parse_markdown_draft(text)
    assert spec.to == ["a@b.com"]
    assert spec.subject == "Hi"
    assert spec.body.strip() == "Body line"


def test_attach_multiline_and_aliases() -> None:
    text = (
        "---\n"
        "To: a@b.com\n"
        "Subject: x\n"
        "Attachments: one.txt\n"
        "  two.txt\n"
        "---\n"
        "\n"
        "hi\n"
    )
    spec = parse_markdown_draft(text)
    assert spec.attach == ["one.txt", "two.txt"]


def test_reply_to_message_id_alias() -> None:
    text = (
        "---\n"
        "To: a@b.com\n"
        "Subject: x\n"
        "Reply-To-Message-Id: bare-id@host\n"
        "---\n"
        "\n"
        "hi\n"
    )
    spec = parse_markdown_draft(text)
    assert spec.in_reply_to == "bare-id@host"


def test_format_plain() -> None:
    text = "---\nTo: a@b.com\nSubject: x\nFormat: plain\n---\n\nplain body\n"
    spec = parse_markdown_draft(text)
    assert spec.format == "plain"
    assert spec.body.strip() == "plain body"


def test_normalize_message_id() -> None:
    assert normalize_message_id("") == ""
    assert normalize_message_id("  <a@b>  ") == "<a@b>"
    assert normalize_message_id("a@b") == "<a@b>"
    assert normalize_message_id("<a@b") == "<a@b>"
    assert normalize_message_id("a@b>") == "<a@b>"


def test_resolve_attachments_relative_and_missing(tmp_path: Path) -> None:
    md = tmp_path / "draft.md"
    attach = tmp_path / "files" / "note.txt"
    attach.parent.mkdir()
    attach.write_text("hi", encoding="utf-8")
    md.write_text(
        "---\nTo: a@b.com\nSubject: x\nAttach: files/note.txt\n---\n\nbody\n",
        encoding="utf-8",
    )
    spec = parse_markdown_draft(md.read_text(encoding="utf-8"), source_path=md)
    paths = resolve_attachments(spec)
    assert paths == [attach.resolve()]

    # Missing files are skipped so Mail can still open the draft.
    spec.attach = ["missing.bin"]
    assert resolve_attachments(spec) == []


def test_attach_preserves_quoted_commas(tmp_path: Path) -> None:
    odd = tmp_path / "report, final.pdf"
    odd.write_bytes(b"%PDF")
    md = tmp_path / "d.md"
    md.write_text(
        '---\nTo: a@b.com\nSubject: x\nAttach: "report, final.pdf", other.txt\n'
        "---\n\nhi\n",
        encoding="utf-8",
    )
    (tmp_path / "other.txt").write_text("x", encoding="utf-8")
    spec = parse_markdown_draft(md.read_text(encoding="utf-8"), source_path=md)
    assert spec.attach == ["report, final.pdf", "other.txt"]
    assert resolve_attachments(spec) == [odd.resolve(), (tmp_path / "other.txt").resolve()]


def test_resolve_attachments_absolute_denied(tmp_path: Path) -> None:
    f = tmp_path / "abs.txt"
    f.write_text("x", encoding="utf-8")
    md = tmp_path / "d.md"
    md.write_text("y", encoding="utf-8")
    from engine.draft_md import DraftSpec

    spec = DraftSpec(attach=[str(f)], source_path=md)
    with pytest.raises(ValueError, match="relative"):
        resolve_attachments(spec)


def test_resolve_attachments_tilde_denied(tmp_path: Path) -> None:
    md = tmp_path / "d.md"
    md.write_text("y", encoding="utf-8")
    from engine.draft_md import DraftSpec

    spec = DraftSpec(attach=["~/secret.txt"], source_path=md)
    with pytest.raises(ValueError, match="relative"):
        resolve_attachments(spec)


def test_resolve_attachments_parent_relative(tmp_path: Path) -> None:
    drafts = tmp_path / "Email" / "Drafts"
    source = tmp_path / "_source_files"
    drafts.mkdir(parents=True)
    source.mkdir()
    pdf = source / "scan.pdf"
    pdf.write_bytes(b"%PDF")
    md = drafts / "d.md"
    md.write_text(
        "---\nTo: a@b.com\nSubject: x\n"
        "Attach: ../../_source_files/scan.pdf\n---\n\nbody\n",
        encoding="utf-8",
    )
    spec = parse_markdown_draft(md.read_text(encoding="utf-8"), source_path=md)
    assert resolve_attachments(spec) == [pdf.resolve()]


def test_split_addrs_preserves_quoted_commas() -> None:
    text = (
        '---\nTo: "Last, First" <a@b.com>, other@x.com\n'
        "Subject: x\n---\n\nhi\n"
    )
    spec = parse_markdown_draft(text)
    assert spec.to == ['"Last, First" <a@b.com>', "other@x.com"]
