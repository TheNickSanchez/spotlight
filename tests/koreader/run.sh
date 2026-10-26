#!/bin/bash
# End-to-end test: Spotlight inside real KOReader (headless), on a real EPUB.
#
# Usage:  tests/koreader/run.sh <path to KOReader.app> <book.epub> [start page]
#
# KOReader.app is the macOS build from KOReader's nightly releases
# (github.com/koreader/koreader/releases, tag "ota"). Nothing is installed:
# KOReader runs with a throwaway settings folder, and the current
# spotlight.koplugin is copied into it for each run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$here/../.." && pwd)"
app="$1"; book="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; page="${3:-20}"
koreader="$app/Contents/koreader"
home="$(mktemp -d -t spotlight-e2e)"
mkdir -p "$home/plugins"
cp -R "$project/spotlight.koplugin" "$home/plugins/"
cd "$koreader"
set +e
KO_HOME="$home" EMULATE_READER_DPI=300 ./luajit "$here/e2e.lua" "$book" "$page" > "$home/e2e.log" 2>&1
status=$?
grep -E '^(PASS|FAIL|==|Done|shots:)|Spotlight' "$home/e2e.log" | grep -v 'INFO  (Looking|Inhibiting|  loading|  rendering)'
echo "Settings folder, screenshots and full log (e2e.log): $home"
exit $status
