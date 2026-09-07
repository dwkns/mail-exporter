"""Match rules: nested groups of Mail-style conditions.

Supports:
  (A ∨ B ∨ C) ∧ (D ∨ E)  via top-level conjunction "all" over groups,
  each group with conjunction "any".

Flat legacy form { conjunction, conditions } is one group.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from email.header import decode_header, make_header
from email.utils import parsedate_to_datetime
from typing import Any, Literal


TEXT_FIELDS = frozenset({"from", "to", "cc", "recipient", "subject", "body", "entire"})
DATE_FIELDS = frozenset({"date"})
TEXT_OPS = frozenset({"contains", "is", "does_not_contain"})
DATE_OPS = frozenset({"after", "before"})

FIELD_ALIASES = {
    "entire message": "entire",
    "entiremessage": "entire",
    "message": "entire",
    "date received": "date",
    "datereceived": "date",
    "any recipient": "recipient",
    "anyrecipient": "recipient",
    "recipients": "recipient",
    "to or cc": "recipient",
    "toorcc": "recipient",
}


@dataclass
class Clause:
    field: str
    op: str
    values: list[str] | None = None
    date_value: date | None = None

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"field": self.field, "op": self.op}
        if self.field in DATE_FIELDS:
            d["date"] = self.date_value.isoformat() if self.date_value else None
        else:
            d["values"] = list(self.values or [])
        return d


@dataclass
class MatchGroup:
    """One group: conjunction 'any' (OR) or 'all' (AND) over conditions."""

    conjunction: Literal["any", "all"]
    clauses: list[Clause]

    def to_dict(self) -> dict[str, Any]:
        return {
            "conjunction": self.conjunction,
            "conditions": [c.to_dict() for c in self.clauses],
        }


@dataclass
class MatchSpec:
    """Top-level: conjunction over groups (typically 'all' of OR-groups)."""

    conjunction: Literal["any", "all"]
    groups: list[MatchGroup]

    def to_dict(self) -> dict[str, Any]:
        # Always emit groups so nested logic round-trips.
        return {
            "conjunction": self.conjunction,
            "groups": [g.to_dict() for g in self.groups],
        }

    @property
    def clauses(self) -> list[Clause]:
        """Flattened clauses (search terms / legacy helpers)."""
        out: list[Clause] = []
        for g in self.groups:
            out.extend(g.clauses)
        return out


def parse_date(value: str) -> date:
    value = value.strip()
    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%d %b %Y", "%d %B %Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).date()
    except ValueError as exc:
        raise ValueError(f"invalid date: {value!r}") from exc


def _normalize_field(raw: str) -> str:
    key = raw.strip().lower()
    return FIELD_ALIASES.get(key, key)


def _normalize_op(raw: str) -> str:
    op = raw.strip().lower().replace(" ", "_")
    aliases = {
        "does_not_contain": "does_not_contain",
        "doesnotcontain": "does_not_contain",
        "not_contains": "does_not_contain",
    }
    return aliases.get(op, op)


def _parse_conjunction(raw: Any, label: str) -> Literal["any", "all"]:
    mode = str(raw or "all").strip().lower()
    if mode not in ("any", "all"):
        raise ValueError(f"{label} must be 'any' or 'all'")
    return mode  # type: ignore[return-value]


def _parse_clause(item: dict[str, Any], label: str) -> Clause:
    field = _normalize_field(str(item.get("field", "")))
    op = _normalize_op(str(item.get("op", "")))
    if field in TEXT_FIELDS:
        if op not in TEXT_OPS:
            raise ValueError(f"{label}: op must be contains|is|does_not_contain for {field}")
        values = item.get("values")
        # Allow single "value" string (Mail-row style)
        if values is None and item.get("value") is not None:
            values = [str(item.get("value"))]
        if not isinstance(values, list) or not any(str(v).strip() for v in values):
            raise ValueError(f"{label}: values must be a non-empty array")
        cleaned = [str(v).strip() for v in values if str(v).strip()]
        return Clause(field=field, op=op, values=cleaned)
    if field in DATE_FIELDS:
        if op not in DATE_OPS:
            raise ValueError(f"{label}: op must be after|before for date")
        dv = item.get("date") or item.get("value")
        if not dv:
            raise ValueError(f"{label}: date is required")
        return Clause(field="date", op=op, date_value=parse_date(str(dv)))
    raise ValueError(
        f"{label}: unsupported field {field!r} "
        f"(use entire|from|to|cc|recipient|subject|body|date)"
    )


def _parse_conditions(raw: Any, label: str) -> list[Clause]:
    if not isinstance(raw, list) or not raw:
        raise ValueError(f"{label} must be a non-empty array")
    return [_parse_clause(item, f"{label}[{i}]") for i, item in enumerate(raw)]


def _parse_group(raw: dict[str, Any], label: str) -> MatchGroup:
    conjunction = _parse_conjunction(
        raw.get("conjunction") or raw.get("mode"), f"{label}.conjunction"
    )
    if "conditions" in raw:
        conditions = raw.get("conditions")
    elif "any" in raw:
        conjunction = "any"
        conditions = raw.get("any")
    elif "all" in raw:
        conjunction = "all"
        conditions = raw.get("all")
    else:
        raise ValueError(f"{label} must include conditions")
    return MatchGroup(
        conjunction=conjunction,
        clauses=_parse_conditions(conditions, f"{label}.conditions"),
    )


def parse_match(raw: dict[str, Any] | None) -> MatchSpec:
    if not raw or not isinstance(raw, dict):
        raise ValueError("match object required")

    # Nested groups: (group1) AND/OR (group2)
    if "groups" in raw:
        groups_raw = raw.get("groups")
        if not isinstance(groups_raw, list) or not groups_raw:
            raise ValueError("match.groups must be a non-empty array")
        top = _parse_conjunction(
            raw.get("conjunction") or raw.get("mode") or "all",
            "match.conjunction",
        )
        groups = [
            _parse_group(item, f"match.groups[{i}]")
            for i, item in enumerate(groups_raw)
            if isinstance(item, dict)
        ]
        if not groups:
            raise ValueError("match.groups must contain at least one group")
        return MatchSpec(conjunction=top, groups=groups)

    # Flat legacy: one group
    conjunction: Literal["any", "all"] = "all"
    conditions: list | None = None

    if "conditions" in raw:
        conjunction = _parse_conjunction(
            raw.get("conjunction") or raw.get("mode") or "all",
            "match.conjunction",
        )
        conditions = raw.get("conditions")
    elif "any" in raw:
        conjunction = "any"
        conditions = raw.get("any")
    elif "all" in raw:
        conjunction = "all"
        conditions = raw.get("all")
    else:
        raise ValueError("match must include groups or conditions (or any/all)")

    clauses = _parse_conditions(conditions, "match.conditions")
    return MatchSpec(
        conjunction="all",
        groups=[MatchGroup(conjunction=conjunction, clauses=clauses)],
    )


def decode_mime_header(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def header_value(msg_bytes: bytes, name: str) -> str | None:
    import re

    if b"\r\n\r\n" in msg_bytes:
        head = msg_bytes.split(b"\r\n\r\n", 1)[0]
    else:
        head = msg_bytes.split(b"\n\n", 1)[0]
    text = head.decode("utf-8", errors="replace")
    text = re.sub(r"\r?\n[ \t]+", " ", text)
    m = re.search(rf"(?im)^{re.escape(name)}:\s*(.+)$", text)
    return m.group(1).strip() if m else None


def message_date(msg_bytes: bytes) -> date | None:
    raw = header_value(msg_bytes, "Date")
    if not raw:
        return None
    try:
        return parsedate_to_datetime(raw).astimezone().date()
    except Exception:
        return None


def field_text(msg_bytes: bytes, field: str) -> str:
    if field == "from":
        return decode_mime_header(header_value(msg_bytes, "From"))
    if field == "to":
        return decode_mime_header(header_value(msg_bytes, "To"))
    if field == "cc":
        return decode_mime_header(header_value(msg_bytes, "Cc"))
    if field == "recipient":
        # Mail “Any Recipient”: To + Cc + Bcc
        parts = [
            decode_mime_header(header_value(msg_bytes, "To")),
            decode_mime_header(header_value(msg_bytes, "Cc")),
            decode_mime_header(header_value(msg_bytes, "Bcc")),
        ]
        return "\n".join(p for p in parts if p)
    if field == "subject":
        return decode_mime_header(header_value(msg_bytes, "Subject"))
    if field in ("body", "entire"):
        # Entire message / Body: search full RFC822 (headers + body)
        return msg_bytes.decode("utf-8", errors="replace")
    return ""


def _norm_addr(s: str) -> str:
    s = s.strip().lower()
    if "<" in s and ">" in s:
        import re

        m = re.search(r"<([^>]+)>", s)
        if m:
            return m.group(1).strip().lower()
    return s


def clause_matches(clause: Clause, msg_bytes: bytes) -> bool:
    if clause.field == "date":
        msg_d = message_date(msg_bytes)
        if msg_d is None or clause.date_value is None:
            return False
        if clause.op == "after":
            return msg_d > clause.date_value
        if clause.op == "before":
            return msg_d < clause.date_value
        return False

    text = field_text(msg_bytes, clause.field)
    values = clause.values or []
    text_l = text.lower()

    if clause.op == "does_not_contain":
        return all(v.lower() not in text_l for v in values)

    if clause.field in ("from", "to", "cc", "recipient") and clause.op == "is":
        needle_set = {_norm_addr(v) for v in values}
        candidates = {_norm_addr(text), text.strip().lower()}
        return bool(needle_set & candidates) or any(
            n in text_l for n in needle_set
        )

    if clause.op == "is":
        return any(text_l == v.lower() for v in values)
    # contains — multiple values in one clause are OR
    return any(v.lower() in text_l for v in values)


def group_matches(group: MatchGroup, msg_bytes: bytes) -> bool:
    if not group.clauses:
        return False
    results = [clause_matches(c, msg_bytes) for c in group.clauses]
    if group.conjunction == "any":
        return any(results)
    return all(results)


def match_message(spec: MatchSpec, msg_bytes: bytes) -> bool:
    if not spec.groups:
        return False
    results = [group_matches(g, msg_bytes) for g in spec.groups]
    if spec.conjunction == "any":
        return any(results)
    return all(results)


def search_terms(spec: MatchSpec) -> list[str]:
    terms: list[str] = []
    for c in spec.clauses:
        if c.field in TEXT_FIELDS and c.values and c.op != "does_not_contain":
            terms.extend(c.values)
    return terms
