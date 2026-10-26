#!/bin/bash
# Renders the README images into docs/images, in real KOReader (headless,
# Paperwhite-sized), on the opening of Pride and Prejudice (Project Gutenberg
# EPUB with illustrations, https://www.gutenberg.org/ebooks/1342).
#
# Usage:  tests/koreader/screenshots.sh <path to KOReader.app> <pride-and-prejudice.epub>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$here/../.." && pwd)"
app="$1"; book="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
home="$(mktemp -d -t spotlight-shots)"
raw="$home/raw"
images="$project/docs/images"
mkdir -p "$home/plugins" "$raw" "$images"
cp -R "$project/spotlight.koplugin" "$home/plugins/"
cd "$app/Contents/koreader"
KO_HOME="$home" EMULATE_READER_DPI=300 ./luajit "$here/screenshots.lua" "$book" "$raw" > "$home/log.txt" 2>&1 \
    || { tail -30 "$home/log.txt"; exit 1; }
grep -E '^(wrote|done)' "$home/log.txt" | tail -3

# The animation: the light moving one sentence at a time.
# Cropped to the text (the bottom of this page is empty).
python3 "$here/make_gif.py" "$images/spotlight.gif" 1300 690 "$raw"/frame-*.pgm

# Full pages at half size, comparison strips at 900 px wide.
for name in hero-day hero-night menu auto-ready auto speed-panel stats; do
    sips --resampleWidth 618 "$raw/$name.png" --out "$images/$name.png" > /dev/null
done
sips --resampleWidth 900 "$raw/looks.png" --out "$images/looks.png" > /dev/null
ls -la "$images"
