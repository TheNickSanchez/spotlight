#!/bin/bash
# End-to-end test: Spotlight inside real KOReader (headless), on a real EPUB.
#
# Usage:  tests/koreader/run.sh <KOReader> <book.epub> [start page]
#
# <KOReader> is either the macOS app (KOReader.app, from KOReader's nightly
# releases, tag "ota") or the folder of a Linux build
# (koreader-linux-x86_64-*.tar.xz from github.com/koreader/koreader/releases,
# unpacked: the folder that holds reader.lua). Nothing is installed:
# KOReader runs with a throwaway settings folder, and the current
# spotlight.koplugin is copied into it for each run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$here/../.." && pwd)"
app="$1"; book="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; page="${3:-20}"
if [ -d "$app/Contents/koreader" ]; then
    koreader="$app/Contents/koreader"   # macOS app
else
    koreader="$app"                     # Linux build folder
fi
[ -f "$koreader/reader.lua" ] || { echo "No KOReader found in $app"; exit 2; }
home="$(mktemp -d "${TMPDIR:-/tmp}/spotlight-e2e.XXXXXX")"
mkdir -p "$home/plugins"
cp -R "$project/spotlight.koplugin" "$home/plugins/"
cd "$koreader"
set +e
KO_HOME="$home" EMULATE_READER_DPI=300 ./luajit "$here/e2e.lua" "$book" "$page" > "$home/e2e.log" 2>&1
status=$?
grep -E '^(PASS|FAIL|==|Done|shots:)|Spotlight' "$home/e2e.log" | grep -v 'INFO  (Looking|Inhibiting|  loading|  rendering)'
if [ $status -ne 0 ] && ! grep -q '^Done:' "$home/e2e.log"; then
    echo "KOReader stopped before the test finished. The end of its log:"
    tail -40 "$home/e2e.log"
fi
echo "Settings folder, screenshots and full log (e2e.log): $home"
exit $status
