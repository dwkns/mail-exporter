"""Parse Make-Mail-Draft style Markdown (.md with fenced front matter)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class DraftSpec:
    to: list[str] = field(default_factory=list)
    cc: list[str] = field(default_factory=list)
    bcc: list[str] = field(default_factory=list)
    subject: str = ""
    from_addr: str = ""
    in_reply_to: str = ""
    reply_mode: str = "auto"  # auto | reply | reply-all | new
    format: str = "markdown"  # markdown | plain
    attach: list[str] = field(default_factory=list)
    body: str = ""
    source_path: Path | None = None


_FENCE = re.compile(r"^---\s*$", re.M)


def _split_addrs(raw: str) -> list[str]:
    """Split addresses on commas that are not inside quotes or angle brackets."""
    raw = raw.strip()
    if not raw:
        return []
    parts: list[str] = []
    buf: list[str] = []
    in_quotes = False
    angle = 0
    for ch in raw:
        if ch == '"' and angle == 0:
            in_quotes = not in_quotes
            buf.append(ch)
            continue
        if not in_quotes:
            if ch == "<":
                angle += 1
            elif ch == ">" and angle:
                angle -= 1
            elif ch == "," and angle == 0:
                piece = "".join(buf).strip()
                if piece:
                    parts.append(piece)
                buf = []
                continue
        buf.append(ch)
    piece = "".join(buf).strip()
    if piece:
        parts.append(piece)
    return parts


def _strip_attach_quotes(raw: str) -> str:
    s = raw.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def _split_attach_list(raw: str) -> list[str]:
    """Split Attach: values on commas/semicolons/newlines outside double quotes."""
    raw = raw.strip()
    if not raw:
        return []
    parts: list[str] = []
    buf: list[str] = []
    in_quotes = False
    for ch in raw:
        if ch == '"':
            in_quotes = not in_quotes
            buf.append(ch)
            continue
        if not in_quotes and ch in ",;\n":
            piece = _strip_attach_quotes("".join(buf))
            if piece:
                parts.append(piece)
            buf = []
            continue
        buf.append(ch)
    piece = _strip_attach_quotes("".join(buf))
    if piece:
        parts.append(piece)
    return parts


def _parse_headers(block: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    current: str | None = None
    for line in block.splitlines():
        if not line.strip():
            continue
        m = re.match(r"^([A-Za-z][A-Za-z0-9-]*)\s*:\s*(.*)$", line)
        if m:
            key = m.group(1).strip().lower()
            val = m.group(2).strip()
            current = key
            if key in ("attach", "attachment", "attachments"):
                prev = headers.get("attach", "")
                headers["attach"] = f"{prev}, {val}" if prev else val
                current = "attach"
            else:
                headers[key] = val
        elif current == "attach":
            prev = headers.get("attach", "")
            extra = line.strip()
            headers["attach"] = f"{prev}, {extra}" if prev else extra
        elif current:
            headers[current] = f"{headers[current]} {line.strip()}".strip()
    return headers


def parse_markdown_draft(text: str, *, source_path: Path | None = None) -> DraftSpec:
    """Parse fenced --- front matter or legacy headers-until-blank-line."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    header_block = ""
    body = text

    if text.lstrip().startswith("---"):
        parts = _FENCE.split(text.lstrip(), maxsplit=2)
        if len(parts) >= 3:
            header_block = parts[1]
            body = parts[2].lstrip("\n")
        else:
            body = text
    else:
        chunks = re.split(r"\n\s*\n", text, maxsplit=1)
        if len(chunks) == 2 and re.search(r"(?im)^(to|subject)\s*:", chunks[0]):
            header_block = chunks[0]
            body = chunks[1]
        else:
            body = text

    h = _parse_headers(header_block)
    attach_raw = h.get("attach") or h.get("attachment") or h.get("attachments") or ""
    attach_parts = _split_attach_list(attach_raw)

    reply = (h.get("reply") or "auto").strip().lower()
    fmt = (h.get("format") or "markdown").strip().lower()
    in_reply = (h.get("in-reply-to") or h.get("reply-to-message-id") or "").strip()

    return DraftSpec(
        to=_split_addrs(h.get("to", "")),
        cc=_split_addrs(h.get("cc", "")),
        bcc=_split_addrs(h.get("bcc", "")),
        subject=(h.get("subject") or "").strip(),
        from_addr=(h.get("from") or "").strip(),
        in_reply_to=in_reply,
        reply_mode=reply,
        format="plain" if fmt == "plain" else "markdown",
        attach=attach_parts,
        body=body.strip("\n"),
        source_path=source_path,
    )


def resolve_attachments(spec: DraftSpec) -> list[Path]:
    """Resolve Attach: paths relative to the .md file (``..`` is allowed).

    Missing files are skipped (Mail still opens the draft and reports them).
    Absolute paths and ``~/…`` raise ValueError.
    """
    base = (spec.source_path.parent if spec.source_path else Path.cwd()).resolve()
    out: list[Path] = []
    denied: list[str] = []
    for raw in spec.attach:
        expanded = Path(raw).expanduser()
        if expanded.is_absolute() or raw.startswith("~"):
            denied.append(raw)
            continue
        p = (base / expanded).resolve()
        if p.is_file():
            out.append(p)
    if denied:
        raise ValueError(
            "attachment path(s) must be relative (no absolute or ~/…): "
            + ", ".join(denied)
        )
    return out


def normalize_message_id(raw: str) -> str:
    s = raw.strip()
    if not s:
        return ""
    if not s.startswith("<"):
        s = "<" + s
    if not s.endswith(">"):
        s = s + ">"
    return s
