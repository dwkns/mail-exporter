"""Read Apple Mail .emlx files and reassemble external attachments."""

from __future__ import annotations

import hashlib
import re
from datetime import datetime
from email import encoders, policy
from email.parser import BytesParser
from email.utils import parsedate_to_datetime
from pathlib import Path

from .criteria import decode_mime_header, header_value

SKIP_PATH_PARTS_ALWAYS = (
    "/Drafts.mbox/",
    "/Junk.mbox/",
    "/Spam.mbox/",
    "/Outbox.mbox/",
    "[Gmail].mbox/Spam/",
)

SKIP_PATH_PARTS_BIN = (
    "/Trash.mbox/",
    "/Deleted Messages.mbox/",
    "/Deleted Items.mbox/",
    "[Gmail].mbox/Bin/",
)

SKIP_PATH_PARTS_SENT = (
    "/Sent Messages.mbox/",
    "/Sent.mbox/",
    "[Gmail].mbox/Sent Mail/",
)

MAIL_DATA_CANDIDATES = [
    Path.home() / "Library/Mail/V10/MailData",
    Path.home() / "Library/Mail/V9/MailData",
    Path.home() / "Library/Mail/V8/MailData",
]

FDA_HELP = (
    "macOS blocked access to ~/Library/Mail (Full Disk Access required).\n"
    "System Settings → Privacy & Security → Full Disk Access — enable MailExporter,\n"
    "then quit and reopen the app."
)


class MailAccessError(RuntimeError):
    pass


def find_mail_root() -> Path:
    saw_perm = False
    for data in MAIL_DATA_CANDIDATES:
        try:
            if (data / "SyncedSmartMailboxes.plist").is_file() or (
                data / "Envelope Index"
            ).is_file():
                return data.parent
        except PermissionError:
            saw_perm = True
    if saw_perm:
        raise MailAccessError(FDA_HELP)
    raise MailAccessError("could not find ~/Library/Mail/V*/MailData")


def should_skip_path(
    path: str,
    *,
    include_sent: bool = True,
    include_bin: bool = False,
) -> bool:
    for part in SKIP_PATH_PARTS_ALWAYS:
        if part in path:
            return True
    if re.search(r"/Drafts\.mbox/", path, re.I):
        return True
    if not include_bin:
        for part in SKIP_PATH_PARTS_BIN:
            if part in path:
                return True
    if not include_sent:
        for part in SKIP_PATH_PARTS_SENT:
            if part in path:
                return True
    return False


def read_emlx_rfc822(path: Path) -> bytes:
    raw = path.read_bytes()
    nl = raw.find(b"\n")
    if nl < 0:
        raise ValueError(f"invalid emlx: {path}")
    try:
        nbytes = int(raw[:nl].strip())
    except ValueError as exc:
        raise ValueError(f"invalid emlx byte count: {path}") from exc
    start = nl + 1
    return raw[start : start + nbytes]


def attachments_dir_for(emlx_path: Path) -> Path | None:
    name = emlx_path.name
    if name.endswith(".partial.emlx"):
        mid = name[: -len(".partial.emlx")]
    elif name.endswith(".emlx"):
        mid = name[: -len(".emlx")]
    else:
        return None
    att = emlx_path.parent.parent / "Attachments" / mid
    return att if att.is_dir() else None


def _attachment_file_for_part(att_dir: Path, mime_path: str) -> Path | None:
    parts = mime_path.split(".")
    rel = ".".join(parts[1:]) if len(parts) >= 2 else mime_path
    folder = att_dir / rel
    if not folder.is_dir():
        return None
    files = sorted(
        p for p in folder.iterdir() if p.is_file() and not p.name.startswith(".")
    )
    return files[0] if files else None


def reassemble_with_attachments(msg_bytes: bytes, att_dir: Path) -> tuple[bytes, int]:
    msg = BytesParser(policy=policy.default).parsebytes(msg_bytes)
    filled = 0

    def fill(part, mime_path: str) -> None:
        nonlocal filled
        if part.is_multipart():
            for i, sub in enumerate(part.iter_parts(), start=1):
                child = f"{mime_path}.{i}" if mime_path else str(i)
                fill(sub, child)
            return
        payload = part.get_payload(decode=True)
        if payload:
            return
        filename = part.get_filename()
        apple_len = part.get("X-Apple-Content-Length")
        if not filename and not apple_len:
            return
        src = _attachment_file_for_part(att_dir, mime_path)
        if src is None:
            return
        data = src.read_bytes()
        part.set_payload(data)
        if "Content-Transfer-Encoding" in part:
            del part["Content-Transfer-Encoding"]
        encoders.encode_base64(part)
        if "X-Apple-Content-Length" in part:
            del part["X-Apple-Content-Length"]
        filled += 1

    fill(msg, "1")
    if filled == 0:
        return msg_bytes, 0
    return msg.as_bytes(policy=policy.SMTP), filled


def message_stable_id(msg_bytes: bytes, path: Path) -> str:
    mid = header_value(msg_bytes, "Message-ID") or header_value(msg_bytes, "Message-Id")
    if mid:
        return mid.strip()
    return f"emlx:{path}"


def short_id(stable_id: str) -> str:
    return hashlib.sha1(stable_id.encode("utf-8")).hexdigest()[:12]


def sanitize_subject(subject: str) -> str:
    s = subject or "no-subject"
    s = re.sub(r'[\/\\:\*\?"<>\|\r\n\t]+', " ", s)
    s = re.sub(r"\s+", " ", s).strip() or "no-subject"
    return s[:80].strip()


def message_timestamp(msg_bytes: bytes, path: Path) -> datetime:
    date_hdr = header_value(msg_bytes, "Date")
    if date_hdr:
        try:
            return parsedate_to_datetime(date_hdr).astimezone().replace(tzinfo=None)
        except Exception:
            pass
    return datetime.fromtimestamp(path.stat().st_mtime)


def prefer_full_emlx(paths: list[Path]) -> list[Path]:
    best: dict[tuple[Path, str], Path] = {}
    for path in paths:
        name = path.name
        if name.endswith(".partial.emlx"):
            mid = name[: -len(".partial.emlx")]
        elif name.endswith(".emlx"):
            mid = name[: -len(".emlx")]
        else:
            mid = path.stem
        key = (path.parent.resolve(), mid)
        prev = best.get(key)
        if prev is None:
            best[key] = path
        elif prev.name.endswith(".partial.emlx") and not path.name.endswith(
            ".partial.emlx"
        ):
            best[key] = path
    return sorted(best.values(), key=lambda p: str(p))


def load_message_bytes(
    path: Path,
    *,
    raw: bytes | None = None,
) -> tuple[bytes, int]:
    msg = raw if raw is not None else read_emlx_rfc822(path)
    filled = 0
    att = attachments_dir_for(path)
    if att is not None:
        msg, filled = reassemble_with_attachments(msg, att)
    return msg, filled
