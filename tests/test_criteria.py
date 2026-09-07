"""Unit tests for criteria matching (no Mail access required)."""

from __future__ import annotations

import unittest

from engine.criteria import match_message, parse_match


def msg(from_addr: str, subject: str, body: str, date_hdr: str) -> bytes:
    return (
        f"From: {from_addr}\r\n"
        f"Subject: {subject}\r\n"
        f"Date: {date_hdr}\r\n"
        f"Message-ID: <test@example.com>\r\n"
        f"\r\n"
        f"{body}\r\n"
    ).encode()


class CriteriaTests(unittest.TestCase):
    def test_from_or_and_date(self) -> None:
        spec = parse_match(
            {
                "conjunction": "all",
                "conditions": [
                    {
                        "field": "from",
                        "op": "is",
                        "values": ["xxx@dhl.com", "yyy@dhl.com"],
                    },
                    {"field": "date", "op": "after", "date": "2026-03-04"},
                ],
            }
        )
        hit = msg(
            "DHL <xxx@dhl.com>",
            "Shipment",
            "hello",
            "Wed, 5 Mar 2026 10:00:00 +0000",
        )
        miss_from = msg(
            "other@example.com",
            "Shipment",
            "hello",
            "Wed, 5 Mar 2026 10:00:00 +0000",
        )
        miss_date = msg(
            "xxx@dhl.com",
            "Shipment",
            "hello",
            "Tue, 3 Mar 2026 10:00:00 +0000",
        )
        self.assertTrue(match_message(spec, hit))
        self.assertFalse(match_message(spec, miss_from))
        self.assertFalse(match_message(spec, miss_date))

    def test_any_entire(self) -> None:
        spec = parse_match(
            {
                "conjunction": "any",
                "conditions": [
                    {"field": "entire", "op": "contains", "values": ["example.org"]},
                    {"field": "entire", "op": "contains", "values": ["example.net"]},
                ],
            }
        )
        self.assertTrue(
            match_message(
                spec,
                msg("a@b.com", "x", "See example.net", "Wed, 5 Mar 2026 10:00:00 +0000"),
            )
        )
        self.assertFalse(
            match_message(
                spec,
                msg("a@b.com", "x", "unrelated", "Wed, 5 Mar 2026 10:00:00 +0000"),
            )
        )

    def test_legacy_all_key(self) -> None:
        spec = parse_match(
            {"all": [{"field": "subject", "op": "contains", "values": ["invoice"]}]}
        )
        # Flat form becomes one group; top conjunction is all
        self.assertEqual(spec.groups[0].conjunction, "all")
        self.assertTrue(
            match_message(
                spec,
                msg("a@b.com", "Your Invoice #1", "x", "Wed, 5 Mar 2026 10:00:00 +0000"),
            )
        )

    def test_any_recipient_cc(self) -> None:
        spec = parse_match(
            {
                "conjunction": "all",
                "conditions": [
                    {
                        "field": "recipient",
                        "op": "contains",
                        "values": ["claims@example.com"],
                    }
                ],
            }
        )
        hit = (
            b"From: a@b.com\r\n"
            b"To: other@example.com\r\n"
            b"Cc: Claims Desk <claims@example.com>\r\n"
            b"Subject: x\r\n"
            b"Date: Wed, 5 Mar 2026 10:00:00 +0000\r\n"
            b"\r\n"
            b"hello\r\n"
        )
        miss = (
            b"From: a@b.com\r\n"
            b"To: other@example.com\r\n"
            b"Cc: someone@else.com\r\n"
            b"Subject: x\r\n"
            b"Date: Wed, 5 Mar 2026 10:00:00 +0000\r\n"
            b"\r\n"
            b"hello\r\n"
        )
        self.assertTrue(match_message(spec, hit))
        self.assertFalse(match_message(spec, miss))

    def test_groups_or_and_or(self) -> None:
        """(termA ∨ termB) ∧ (fromX ∨ fromY)"""
        spec = parse_match(
            {
                "conjunction": "all",
                "groups": [
                    {
                        "conjunction": "any",
                        "conditions": [
                            {
                                "field": "entire",
                                "op": "contains",
                                "values": ["billing.example.com"],
                            },
                            {
                                "field": "entire",
                                "op": "contains",
                                "values": ["invoices.example.com"],
                            },
                        ],
                    },
                    {
                        "conjunction": "any",
                        "conditions": [
                            {
                                "field": "from",
                                "op": "contains",
                                "values": ["claims@"],
                            },
                            {
                                "field": "from",
                                "op": "contains",
                                "values": ["support@"],
                            },
                        ],
                    },
                ],
            }
        )
        hit = msg(
            "claims@example.com",
            "x",
            "See invoices.example.com",
            "Wed, 5 Mar 2026 10:00:00 +0000",
        )
        miss_group1 = msg(
            "claims@example.com",
            "x",
            "unrelated",
            "Wed, 5 Mar 2026 10:00:00 +0000",
        )
        miss_group2 = msg(
            "other@example.com",
            "x",
            "invoices.example.com",
            "Wed, 5 Mar 2026 10:00:00 +0000",
        )
        self.assertTrue(match_message(spec, hit))
        self.assertFalse(match_message(spec, miss_group1))
        self.assertFalse(match_message(spec, miss_group2))

    def test_does_not_contain(self) -> None:
        spec = parse_match(
            {
                "conjunction": "all",
                "conditions": [
                    {
                        "field": "subject",
                        "op": "does_not_contain",
                        "values": ["spam", "promo"],
                    }
                ],
            }
        )
        self.assertTrue(
            match_message(
                spec,
                msg("a@b.com", "Invoice", "x", "Wed, 5 Mar 2026 10:00:00 +0000"),
            )
        )
        self.assertFalse(
            match_message(
                spec,
                msg("a@b.com", "Monthly promo", "x", "Wed, 5 Mar 2026 10:00:00 +0000"),
            )
        )

    def test_field_alias_any_recipient(self) -> None:
        spec = parse_match(
            {
                "conjunction": "all",
                "conditions": [
                    {
                        "field": "Any Recipient",
                        "op": "contains",
                        "values": ["claims@example.com"],
                    }
                ],
            }
        )
        hit = (
            b"From: a@b.com\r\n"
            b"To: claims@example.com\r\n"
            b"Subject: x\r\n"
            b"Date: Wed, 5 Mar 2026 10:00:00 +0000\r\n"
            b"\r\n"
            b"hello\r\n"
        )
        self.assertTrue(match_message(spec, hit))

    def test_single_value_alias(self) -> None:
        spec = parse_match(
            {
                "conjunction": "all",
                "conditions": [
                    {"field": "subject", "op": "contains", "value": "invoice"}
                ],
            }
        )
        self.assertTrue(
            match_message(
                spec,
                msg("a@b.com", "Your Invoice", "x", "Wed, 5 Mar 2026 10:00:00 +0000"),
            )
        )

    def test_invalid_match_raises(self) -> None:
        with self.assertRaises(ValueError):
            parse_match({})
        with self.assertRaises(ValueError):
            parse_match({"conjunction": "all", "conditions": []})


if __name__ == "__main__":
    unittest.main()
