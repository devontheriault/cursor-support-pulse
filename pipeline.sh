#!/usr/bin/env bash
# Run everything after the crawl, unattended: wait for crawl.py to finish, then
# propose issues, label every thread, score, match docs, and rebuild data.js.
# Review out/issues.json afterwards; if it changes, rerun from `label.py assign`.
set -euo pipefail
cd "$(dirname "$0")"
py=.venv/bin/python
until $py -c 'import json,sys; sys.exit(0 if json.load(open("raw/crawl.json")).get("finished_at") else 1)' 2>/dev/null; do
  sleep 60
done
echo "crawl finished: $(date)"
$py label.py issues
$py label.py assign
$py build.py
$py label.py docs
$py build.py
$py label.py spot
echo "pipeline finished: $(date)"
