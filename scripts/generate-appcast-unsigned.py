#!/usr/bin/env python3
"""Write an unsigned Sparkle appcast for a MailExporter zip.

The enclosure has no sparkle:edSignature. Sparkle 2 will refuse to install it.
Mini (dwkns-mini-m1) replaces this with a generate_appcast output signed from
the EdDSA private key that stays on that Mac.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
from xml.sax.saxutils import escape


def build_appcast(*, zip_path: str, version: str, build: str, tag: str, asset_name: str) -> str:
    version = version.lstrip("vV")
    tag = tag if tag.startswith("v") else f"v{tag}"
    length = os.path.getsize(zip_path)
    url = f"https://github.com/dwkns/mail-exporter/releases/download/{tag}/{asset_name}"
    pub = dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MailExporter</title>
    <item>
      <title>MailExporter {escape(version)}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{escape(str(build))}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="{escape(url)}" length="{length}" type="application/octet-stream" sparkle:os="macos" />
    </item>
  </channel>
</rss>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--asset-name", default="MailExporter-macOS-arm64.zip")
    args = parser.parse_args()
    xml = build_appcast(
        zip_path=args.zip,
        version=args.version,
        build=args.build,
        tag=args.tag,
        asset_name=args.asset_name,
    )
    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(xml)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
