#!/usr/bin/env python3
"""Shared release helpers: markdown rendering and appcast.xml manipulation.

Subcommands (invoked from bash):
  md-to-html <md_file>
      Print rendered HTML to stdout.

  prepend-item <appcast_path> <new_item_xml>
      Rewrite appcast.xml with new_item at the top of the channel,
      preserving any existing <item> blocks.

  inject-descriptions <appcast_path> <mapping_tsv> <style>
      For each row "<version>\t<html_file>" in mapping_tsv, inject a
      <description> CDATA block into the matching <item> in appcast.xml,
      keyed on <sparkle:shortVersionString>.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

# ── markdown → HTML ───────────────────────────────────────────────────────────

_BULLET = re.compile(r"^[-*]\s+")
_NUMBERED = re.compile(r"^\d+\.\s+")


def _inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*(?!\*)([^*\n]+?)\*(?!\*)", r"<em>\1</em>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def md_to_html(md: str) -> str:
    """Convert a small subset of Markdown to HTML — h1/h2, lists, paragraphs, inline."""
    out: list[str] = []
    lines = md.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if line.startswith("## "):
            out.append(f'<h2>{_inline(line[3:].strip().rstrip("#").strip())}</h2>')
            i += 1
        elif line.startswith("# "):
            out.append(f'<h1>{_inline(line[2:].strip().rstrip("#").strip())}</h1>')
            i += 1
        elif _BULLET.match(line):
            out.append("<ul>")
            while i < len(lines) and _BULLET.match(lines[i]):
                out.append(f'  <li>{_inline(_BULLET.sub("", lines[i]).rstrip())}</li>')
                i += 1
            out.append("</ul>")
        elif _NUMBERED.match(line):
            out.append("<ol>")
            while i < len(lines) and _NUMBERED.match(lines[i]):
                out.append(f'  <li>{_inline(_NUMBERED.sub("", lines[i]).rstrip())}</li>')
                i += 1
            out.append("</ol>")
        elif not line.strip():
            i += 1
        else:
            buf: list[str] = []
            while (
                i < len(lines)
                and lines[i].strip()
                and not lines[i].startswith("#")
                and not _BULLET.match(lines[i])
                and not _NUMBERED.match(lines[i])
            ):
                buf.append(lines[i].strip())
                i += 1
            out.append(f'<p>{_inline(" ".join(buf))}</p>')
    return "\n".join(out)


# ── appcast.xml manipulation ──────────────────────────────────────────────────

_APPCAST_HEADER = """\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Quay</title>
        <link>https://github.com/babul/quay</link>
        <description>Quay update feed</description>
        <language>en</language>"""

_APPCAST_FOOTER = "\n    </channel>\n</rss>\n"

_ITEM_RE = re.compile(r"<item>.*?</item>", re.DOTALL)
_VERSION_RE = re.compile(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>")


def prepend_item(appcast_path: Path, new_item: str) -> None:
    """Rewrite appcast.xml with new_item at the top, preserving existing <item> blocks."""
    try:
        existing = _ITEM_RE.findall(appcast_path.read_text())
    except FileNotFoundError:
        existing = []
    parts = [_APPCAST_HEADER, "\n", new_item, "\n"]
    parts.extend(f"        {item.strip()}\n" for item in existing)
    parts.append(_APPCAST_FOOTER)
    appcast_path.write_text("".join(parts))


def inject_descriptions(appcast_path: Path, mapping_tsv: Path, style: str) -> None:
    """Inject <description> CDATA blocks into matching <item>s by version."""
    html_by_version: dict[str, str] = {}
    for line in mapping_tsv.read_text().splitlines():
        if not line:
            continue
        version, html_file = line.split("\t", 1)
        html_by_version[version] = Path(html_file).read_text()

    def replace(match: re.Match[str]) -> str:
        item_text = match.group(0)
        ver_match = _VERSION_RE.search(item_text)
        if not ver_match:
            return item_text
        version = ver_match.group(1).strip()
        body = html_by_version.get(version)
        if body is None:
            return item_text
        desc = (
            f"            <description><![CDATA[{style}\n"
            f"{body}\n"
            f"            ]]></description>\n"
        )
        # Insert immediately before <enclosure, preserving its attributes.
        return re.sub(r"(\s*<enclosure\s)", lambda mo: desc + mo.group(1), item_text, count=1)

    content = appcast_path.read_text()
    appcast_path.write_text(_ITEM_RE.sub(replace, content))


# ── CLI dispatch ──────────────────────────────────────────────────────────────


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "md-to-html":
        (md_file,) = args
        print(md_to_html(Path(md_file).read_text()))
        return 0
    if cmd == "prepend-item":
        appcast_path, new_item = args
        prepend_item(Path(appcast_path), new_item)
        return 0
    if cmd == "inject-descriptions":
        appcast_path, mapping_tsv, style = args
        inject_descriptions(Path(appcast_path), Path(mapping_tsv), style)
        return 0
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
