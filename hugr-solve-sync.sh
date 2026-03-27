#!/usr/bin/env bash
# hugr-solve-sync.sh -- Sync solve transcripts into the HTML viewer
# Replaces data between EMBEDDED_DATA markers

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

export HS_OUTPUT_DIR="${OUTPUT_DIR:-./output}"
export HS_VIEWER_FILE="${VIEWER_FILE:-./viewer.html}"

if [[ ! -f "$HS_VIEWER_FILE" ]]; then
  echo "Viewer not found at $HS_VIEWER_FILE" >&2
  exit 1
fi

python3 << 'PYEOF'
import json, os, glob, sys, re

output_dir = os.path.expanduser(os.environ["HS_OUTPUT_DIR"])
html_file = os.path.expanduser(os.environ["HS_VIEWER_FILE"])

entries = []
all_files = glob.glob(os.path.join(output_dir, "*.md"))
all_files.sort(key=lambda f: os.path.getmtime(f))
for f in all_files:
    basename = os.path.basename(f)
    m = re.match(r'^(\d{4}-\d{2}-\d{2})-(.+)\.md$', basename)
    if m:
        date = m.group(1)
        topic = m.group(2)
    else:
        date = basename.replace(".md", "")
        topic = ""

    with open(f) as fh:
        content = fh.read().strip()

    entries.append({"date": date, "topic": topic, "content": content})

if not entries:
    print("No solve files found", file=sys.stderr)
    sys.exit(0)

data_str = json.dumps(entries, ensure_ascii=False)

with open(html_file, "r") as f:
    lines = f.readlines()

out = []
skip = False
found_marker = False
for line in lines:
    if "// EMBEDDED_DATA_START" in line:
        out.append(line)
        out.append(f"let SOLVES = {data_str};\n")
        skip = True
        found_marker = True
        continue
    if "// EMBEDDED_DATA_END" in line:
        out.append(line)
        skip = False
        continue
    if not skip:
        out.append(line)

if not found_marker:
    print("ERROR: EMBEDDED_DATA_START marker not found in HTML", file=sys.stderr)
    sys.exit(1)

with open(html_file, "w") as f:
    f.writelines(out)

print(f"Synced {len(entries)} solve sessions to {html_file}")
PYEOF
