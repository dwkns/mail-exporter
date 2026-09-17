"""Howto generator is the single source of truth."""

from engine.howto import how_to_markdown, how_to_template


def test_howto_says_export_not_smart_mailbox() -> None:
    text = how_to_markdown(mailbox_name="DHL", output_dir="/tmp/out")
    assert "Smart mailbox" not in text
    assert "Export: **DHL**" in text
    assert "never leaves this Mac" in text
    assert "no `..`" in text or "No `..`" in text


def test_template_placeholders() -> None:
    text = how_to_template()
    assert "{{MAILBOX_NAME}}" in text
    assert "{{OUTPUT_DIR}}" in text
    assert "Smart mailbox" not in text
