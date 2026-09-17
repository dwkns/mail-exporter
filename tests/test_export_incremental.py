"""Synthetic .emlx mailbox: incremental export, prune, dry-run, drafts→sent."""

from __future__ import annotations

from pathlib import Path

from engine.criteria import parse_match
from engine.export import load_state, run_job
from engine.jobs import Job


def _emlx(rfc822: bytes) -> bytes:
    return f"{len(rfc822)}\n".encode() + rfc822


def _rfc822(
    *,
    mid: str,
    subject: str,
    from_addr: str = "a@b.com",
    body: str = "hello invoice",
    in_reply_to: str = "",
    extra: str = "",
) -> bytes:
    lines = [
        f"From: {from_addr}",
        "To: you@example.com",
        f"Subject: {subject}",
        "Date: Wed, 5 Mar 2026 10:00:00 +0000",
        f"Message-ID: {mid}",
    ]
    if in_reply_to:
        lines.append(f"In-Reply-To: {in_reply_to}")
    if extra:
        lines.append(extra)
    lines.append("")
    lines.append(body)
    return "\r\n".join(lines).encode()


def _write_emlx(folder: Path, name: str, rfc822: bytes) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_bytes(_emlx(rfc822))
    return path


def _job(tmp_path: Path, **kwargs) -> Job:
    out = tmp_path / "out"
    match = parse_match(
        {
            "conjunction": "any",
            "conditions": [
                {"field": "entire", "op": "contains", "values": ["invoice"]}
            ],
        }
    )
    return Job(
        id="job-1",
        name="Receipts",
        output_dir=str(out),
        match=match,
        include_sent=True,
        **kwargs,
    )


def test_dry_run_counts_and_samples(tmp_path: Path, monkeypatch) -> None:
    mail = tmp_path / "mail"
    p1 = _write_emlx(
        mail,
        "1.emlx",
        _rfc822(mid="<a@x>", subject="Your invoice"),
    )
    _write_emlx(
        mail,
        "2.emlx",
        _rfc822(mid="<b@x>", subject="unrelated", body="newsletter"),
    )
    monkeypatch.setattr("engine.export.candidate_paths", lambda *a, **k: [p1, mail / "2.emlx"])
    result = run_job(_job(tmp_path), dry_run=True)
    assert result["dryRun"] is True
    assert result["matchCount"] == 1
    assert result["samples"] == ["Your invoice"]
    assert "1 match" in result["line"]


def test_incremental_export_writes_then_skips(tmp_path: Path, monkeypatch) -> None:
    mail = tmp_path / "mail"
    p1 = _write_emlx(
        mail,
        "1.emlx",
        _rfc822(mid="<a@x>", subject="Your invoice"),
    )
    monkeypatch.setattr("engine.export.candidate_paths", lambda *a, **k: [p1])
    job = _job(tmp_path)
    first = run_job(job)
    assert first["newlyWritten"] == 1
    out = Path(job.output_dir)
    emls = list(out.glob("*.eml"))
    assert len(emls) == 1
    state = load_state(out / ".exported-ids.json")
    assert "<a@x>" in state["files"] or any("a@x" in k for k in state["files"])
    second = run_job(job)
    assert second["newlyWritten"] == 0
    assert second["line"] == "Up to date"
    assert len(list(out.glob("*.eml"))) == 1


def test_force_full_rewrites(tmp_path: Path, monkeypatch) -> None:
    mail = tmp_path / "mail"
    p1 = _write_emlx(
        mail,
        "1.emlx",
        _rfc822(mid="<a@x>", subject="Your invoice"),
    )
    monkeypatch.setattr("engine.export.candidate_paths", lambda *a, **k: [p1])
    job = _job(tmp_path)
    run_job(job)
    again = run_job(job, force_full=True)
    assert again["newlyWritten"] == 1


def test_promote_drafts_to_sent(tmp_path: Path, monkeypatch) -> None:
    mail = tmp_path / "mail"
    p1 = _write_emlx(
        mail,
        "1.emlx",
        _rfc822(mid="<sent@x>", subject="Quote follow-up", body="invoice sent"),
    )
    monkeypatch.setattr("engine.export.candidate_paths", lambda *a, **k: [p1])
    job = _job(tmp_path)
    drafts = Path(job.output_dir) / "Drafts"
    drafts.mkdir(parents=True)
    md = drafts / "001_client_quote-follow-up.md"
    md.write_text(
        "---\nTo: a@b.com\nSubject: Quote follow-up\nIn-Reply-To: <sent@x>\n---\n\nHi\n",
        encoding="utf-8",
    )
    result = run_job(job)
    assert result["draftsPromoted"] == 1
    assert not md.exists()
    assert (Path(job.output_dir) / "Sent" / md.name).is_file()


def test_thread_complete_adds_parent(tmp_path: Path, monkeypatch) -> None:
    mail = tmp_path / "mail"
    parent = _write_emlx(
        mail,
        "parent.emlx",
        _rfc822(mid="<orig@x>", subject="Hello", body="no keyword here"),
    )
    child = _write_emlx(
        mail,
        "child.emlx",
        _rfc822(
            mid="<reply@x>",
            subject="Re: Hello",
            body="invoice",
            in_reply_to="<orig@x>",
        ),
    )
    calls = {"n": 0}

    def candidates(spec, *args, **kwargs):
        calls["n"] += 1
        terms = []
        for group in spec.groups:
            for clause in group.clauses:
                terms.extend(clause.values or [])
        joined = " ".join(terms).lower()
        if "orig@x" in joined and "invoice" not in joined:
            return [parent]
        return [parent, child]

    monkeypatch.setattr("engine.export.candidate_paths", candidates)
    job = _job(tmp_path, include_thread=True)
    result = run_job(job)
    assert result["matchCount"] >= 2
    assert len(list(Path(job.output_dir).glob("*.eml"))) >= 2


def test_attachments_sidecar(tmp_path: Path, monkeypatch) -> None:
    from engine.export import write_attachments_sidecar

    messages = tmp_path / "INBOX.mbox" / "UUID" / "Data" / "Messages"
    att = tmp_path / "INBOX.mbox" / "UUID" / "Data" / "Attachments" / "99"
    att.mkdir(parents=True)
    (att / "scan.pdf").write_bytes(b"%PDF")
    emlx = messages / "99.emlx"
    messages.mkdir(parents=True)
    emlx.write_bytes(_emlx(_rfc822(mid="<a@x>", subject="scan")))
    out = tmp_path / "out"
    out.mkdir()
    written = write_attachments_sidecar(out, "<a@x>", emlx)
    assert written == 1
    files = list((out / "Attachments").rglob("scan.pdf"))
    assert files
