#!/usr/bin/env bash
# lib-md-to-html.sh — shared markdown-to-HTML converter for release scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib-md-to-html.sh"
#   html_body="$(md_to_html "$md_file")"

md_to_html() {
  local md_file="$1"
  python3 - "$md_file" <<'PYEOF'
import sys, re, html as H
md = open(sys.argv[1]).read()

def inline(s):
    s = H.escape(s)
    s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'(?<!\*)\*(?!\*)([^*\n]+?)\*(?!\*)', r'<em>\1</em>', s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', s)
    return s

out, lines, i = [], md.splitlines(), 0
BULLET   = re.compile(r'^[-*]\s+')
NUMBERED = re.compile(r'^\d+\.\s+')

while i < len(lines):
    line = lines[i].rstrip()
    if line.startswith('## '):
        out.append(f'<h2>{inline(line[3:].strip().rstrip("#").strip())}</h2>'); i += 1
    elif line.startswith('# '):
        out.append(f'<h1>{inline(line[2:].strip().rstrip("#").strip())}</h1>'); i += 1
    elif BULLET.match(line):
        out.append('<ul>')
        while i < len(lines) and BULLET.match(lines[i]):
            out.append(f'  <li>{inline(BULLET.sub("", lines[i]).rstrip())}</li>')
            i += 1
        out.append('</ul>')
    elif NUMBERED.match(line):
        out.append('<ol>')
        while i < len(lines) and NUMBERED.match(lines[i]):
            out.append(f'  <li>{inline(NUMBERED.sub("", lines[i]).rstrip())}</li>')
            i += 1
        out.append('</ol>')
    elif not line.strip():
        i += 1
    else:
        buf = []
        while i < len(lines) and lines[i].strip() \
              and not lines[i].startswith('#') \
              and not BULLET.match(lines[i]) \
              and not NUMBERED.match(lines[i]):
            buf.append(lines[i].strip()); i += 1
        out.append(f'<p>{inline(" ".join(buf))}</p>')

print('\n'.join(out))
PYEOF
}
