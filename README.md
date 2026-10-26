# Spotlight for KOReader

A sentence spotlight for reflowable books (EPUB, FB2, HTML, TXT). The current
sentence gets a light gray band behind it and a solid black bar in the left
margin (the trail marker), and the light moves one sentence at a time. Text
stays pure black and the rest of the page is left alone.

Status: **all five milestones are done (M5: session stats)**.
- In Manual mode you move the light with taps or the page keys.
- In Auto mode it moves on its own at the pace learned from your Manual
  reading: hold anywhere to pause, let go to continue.
- Auto-adjust nudges the speed from your holds, backs and skips, and each
  book keeps its own pace.
- Every reading session is recorded. The stats screen shows today, the last
  7 days and the last 30 days, and you can export the sessions as JSON.

## Install on the Kindle

1. Connect the Kindle by USB.
2. Copy the `spotlight.koplugin` folder into `koreader/plugins/` on the
   Kindle, so you have `koreader/plugins/spotlight.koplugin/main.lua`.
   Replace the whole folder when you update.
3. Eject the Kindle, then restart KOReader (top menu → ☰ → Exit, then start
   it again from KUAL). Plugins are only loaded at start.

## Try it on the Mac first

KOReader's stable releases have no macOS app. The macOS app is only in the
nightly builds: on github.com/koreader/koreader/releases, open the release
tagged "ota" and download `koreader-macos-11.0-arm64-….7z` (Apple Silicon)
or `koreader-macos-10.15-x86_64-….7z` (Intel).

1. Start KOReader once and quit it. That creates its settings folder.
2. Copy `spotlight.koplugin` into
   `~/Library/Application Support/koreader/plugins/`.
   If it does not show up, put it inside the app instead:
   right-click KOReader.app → Show Package Contents →
   `Contents/koreader/plugins/`.
3. Start KOReader and open an EPUB.

If the menu entry is missing, the log says where KOReader looked:
search for `Looking for plugins in directory`.

## Where the logs are

Each time a book opens, Spotlight logs one line with its version, for example
`Spotlight 0.5.0 (M5) : ready, turned off`. If that line is missing, KOReader
did not load the plugin. Check that the folder is
`koreader/plugins/spotlight.koplugin` (not nested one level deeper), and
restart KOReader.

- Kindle: `koreader/crash.log` on the USB storage. Errors from the plugin and
  Spotlight's own lines are there. KOReader keeps running if the plugin
  fails: plugin event handlers run in a protected call.
- Mac: `crash.log` in `~/Library/Application Support/koreader/` (or the
  terminal, if you started KOReader from one).

Spotlight writes one line per page it reads, for example
`Spotlight: page 12, 9 sentences from 412 words in 38 ms`. The time is
what Spotlight adds to a page turn.

## Using it

Turn it on: tap the top of the screen to open the menu. In the first tab
(navigation), **Spotlight** is the first entry. Choose **Spotlight** →
**Spotlight on**. The setting is remembered for all books.

For a book Spotlight can't handle (PDF, comics), the entry reads "Spotlight
(not for this book)". If the plugin failed to start, it reads "Spotlight
(could not start)": tap it to see the error.

### Manual mode (gestures)

| Do this | Spotlight does |
|---|---|
| Tap the right three quarters of the screen | Next sentence |
| Tap the left quarter | Previous sentence |
| Forward or back page key | Next or previous sentence |
| Tap a link | Follows the link, as usual |
| Hold | KOReader's usual dictionary and highlighting |
| Swipe, or turn the page any other way | Lights the first sentence on the new page |

- **Taps that stay KOReader's.** The top strip (menu) and the bottom strip
  (settings bar, footer) work as usual. So do the screen corners, and the
  taller tap areas in the middle of the top and bottom edges. Those are
  KOReader's own zones, so sentence taps cover the rest of the screen.
- **Sentences split by a page break.** The visible part is lit first. The
  next tap turns the page and lights the rest. Going back works the same
  way, in reverse.
- **At the end of a page**, the next tap turns the page and lights its first
  sentence.
- **Per book.** The sentence you were on is saved with the book and lit again
  when you open it.

### Learning your pace

The first time you choose Auto, Spotlight first learns how you read. It
stays in Manual mode and says so; you tap through as usual while it times
you.

- **Which timings count.** A sentence counts only if:
  - it wasn't reread;
  - it wasn't the first one after a page turn, or split by one;
  - it took between 120 and 1,500 ms per word, and under a minute in all.
- **When it's done.** After at least 40 such sentences and 3 minutes of
  reading in them (about 2–3 pages), a popup says: "Auto is ready. You read
  about N words a minute. The light will move on its own. Hold anywhere to
  pause; let go to continue."
  - **Start Auto** switches to Auto at that pace.
  - **Keep tapping** stays in Manual mode. The next time you choose Auto, it
    starts at once.
- **Progress.** While learning, Spotlight → Mode shows how far it has got
  ("Auto (learning your pace: 23 of 40 sentences)").
- **If you've already read enough in Manual mode,** the popup appears as
  soon as you choose Auto.

**The pace model.** Each sentence takes a fixed pause plus its words times
your time per word. Both are fitted by least squares to your 150 most
recent valid timings, and the pause is kept between 0.2 and 1.5 s. If the
fit can't be trusted, Spotlight falls back to your median words a minute
with a 0.4 s pause. That happens when there are too few timings, the
sentences are all about the same length, or the result is implausible. The
speed shown everywhere (popup, indicator, panel) is the per-word part; the
short pause per sentence comes on top.

**It keeps learning.** Every valid Manual timing refines your pace, even when
you never use Auto, so it stays current.

**Each book keeps its own pace** once you adjust it there: speed panel,
Faster/Slower, or auto-adjust. Other books start from your learned pace.
Spotlight → Speed shows which applies: "(this book)", "(your pace)" or
"(not learned yet)".

**Learn my pace again** (in the Spotlight menu) forgets your timings and
learned pace, and resets the current book's own speed. Other books keep
theirs. Learning then starts over.

### Auto mode (the pacer)

Spotlight → **Mode** → **Auto**. The light moves on its own at your pace.

| Do this | Spotlight does |
|---|---|
| Touch and hold anywhere | Pauses while your finger is down |
| Let go | Carries on: the time that was left on the sentence, plus 0.5 s |
| Quick tap right (or forward key) | Skips ahead one sentence now |
| Quick tap left (or back key) | Goes back one sentence and carries on from there |
| Swipe or other page turn | Carries on from the first sentence on the new page |
| Tap the top or bottom strip | KOReader's menus open as usual; the light waits until they close |

- **Holds.** The pause starts the moment your finger lands, not when KOReader
  recognizes the hold. In Auto mode holds never open the dictionary or
  start a highlight. If the light moved on in the instant before your
  finger landed (within 0.25 s), it goes back to the sentence you were
  aiming at.
- **Page turns.** The first sentence on a new page gets an extra 0.8 s. A
  sentence split by a page break gets its share of the time on each page.
- **Opening a book in Auto mode, or waking the Kindle**, the light waits for
  your first tap, so you can find your place first. That tap starts it,
  without skipping.
- **At the end of the book** the light stops and waits.
- **The indicator.** "Auto · 200 wpm" shows while Auto mode is on. If
  KOReader's footer is set to show all its items at once, the indicator is
  one of them. Otherwise it is a small label in the bottom-right corner,
  above the footer. (The footer shows one item at a time by default, so
  Spotlight doesn't rely on it.)
- **The Kindle stays awake.** While the light is moving, KOReader's
  auto-suspend and the Kindle's own 10-minute sleep timer are held off, the
  way KOReader's Auto-turn plugin does it. Once the light pauses, they work
  as usual again.

### Speed

Spotlight → **Speed** opens the speed panel. It works like KOReader's
frontlight panel: − and + change the speed by 5 words a minute, and you can
tap or drag along the bar to set it (80 to 400, in steps of 5). Changes
apply at once, even to the sentence that is lit, and are kept for this book.
Tap outside the panel to close it.

### Auto-adjust

Spotlight → **Auto-adjust speed** (on by default). In Auto mode, Spotlight
looks at the sentences in windows of 15:

- Holds and backs are stops; skip-aheads mean the light is too slow.
- 3 or more stops: 5 % slower.
- No stops and at least one skip-ahead: 5 % faster.
- No stops and no skips for two windows in a row: 2 % faster.
- At most one change per window, always within 80–400 words a minute. A
  sentence split by a page break counts once.

Changes show only in the Auto indicator, never as a popup, and are kept for
this book. When you turn Auto off or close the book, a short message shows
how the speed went: "Started at 172, ended at 181 words a minute."

### Stats

Spotlight → **Stats** → **Show stats** (or the "Spotlight: show stats" gesture
action). One screen with today, the last 7 days and the last 30 days:

- minutes read
- sentences
- average pace (words a minute of reading time), with its trend
- stops per 100 sentences (holds and backs), with its trend

Each trend compares with the period before: yesterday, the 7 days before, or
the 30 days before. For example, "200 wpm (+20)" or "5.0 (−1.0)". A dash
means there was no reading to measure.

**What counts.** A session is one stretch of reading in one book: from
opening it to closing it, or until the Kindle has slept more than 30
minutes. Reading time adds up the time between moves of the light. A gap of
more than 90 seconds (you put the Kindle down) is left out. A sentence counts
once you move on from it. A sentence split by a page break counts once, when
you finish its second part.

**Where it is kept.** Sessions are saved in
`koreader/settings/spotlight_stats.json`. A session is saved when the book
closes, and also each time the Kindle goes to sleep, in case the book is
never closed.

**Export.** Spotlight → Stats → **Export stats (JSON)** copies all sessions to
`spotlight/spotlight_stats.json` in KOReader's home folder. On a Kindle that
is a `spotlight` folder at the top of its USB storage. The file looks like
this:

```json
{
  "format": "spotlight-sessions",
  "version": 1,
  "fields": { "active_seconds": "reading time; gaps over 90 seconds are left out", "...": "..." },
  "sessions": [
    {
      "id": "20261025-213322-cb511a",
      "date": "2026-10-25",
      "started_at": "2026-10-25T21:23:37",
      "ended_at": "2026-10-25T21:33:23",
      "book_title": "Pride and Prejudice",
      "active_seconds": 586,
      "manual_seconds": 397,
      "auto_seconds": 189,
      "sentences": 74,
      "words": 1827,
      "average_wpm": 187,
      "holds": 4,
      "backs": 2,
      "skip_aheads": 1,
      "starting_pace_wpm": 200,
      "ending_pace_wpm": 228,
      "auto_adjust_changes": 1
    }
  ]
}
```

Times are local time. `fields` describes every session field, so the file
explains itself when you import it into your web app.

### Gesture actions

Top menu → ⚙ → Taps and gestures → Gesture manager → pick a gesture →
Reader:

- **Toggle Spotlight**
- **Spotlight: next sentence** / **previous sentence**
- **Spotlight: toggle Auto** (also turns Spotlight on)
- **Spotlight: faster (+5 wpm)** / **slower (−5 wpm)**
- **Spotlight: speed panel**
- **Spotlight: show stats**

### Look

Spotlight → Look:

- **Style**: band and bar (default), bar only, or underline only.
- **Band darkness**: light, medium (default, the same gray as KOReader's own
  highlights) or dark.
- **Bar width**: 4, 5 (default) or 6 pixels.
- **In night mode**: how the band looks when KOReader's night mode is on.
  Spotlight follows night mode by itself. There is nothing else to switch.
  - **Bright sentence (day colours)**, the default: the lit sentence is black
    on white, a spotlight on the dark page.
  - **Soft glow (dim band)**: a dark gray band behind the white text.

  (Brighter gray bands were tried and left out. White text on light gray
  gets hard to read.)

The bar sits just left of where the page's lines start, at the same spot
for every sentence on the page. In night mode it is white.

## How it works

- **Timing.** In Manual mode every sentence is timed, from when it lights
  up to your next forward tap (see "Learning your pace" for which ones
  count). Time while the Kindle sleeps is not counted. The kept timings
  (the newest 400), your learned pace and the learning state are saved in
  `koreader/settings/spotlight.lua`. Each book's own pace is saved with the
  book's KOReader settings.

- **Finding sentences.** crengine (KOReader's EPUB engine) has no sentence
  or paragraph API. Spotlight steps through the page word by word and reads
  the text between words. crengine marks every block boundary (paragraph,
  heading, list item, line break) with a newline, so block ends are exact.
  The sentence rules are in `sentences.lua`:
  - A sentence ends at `.` `!` `?` or `…`, plus any closing quotes or
    brackets, followed by whitespace.
  - It does not end after Mr, Mrs, Ms, Dr, Prof, St, vs, etc, e.g, i.e, fig,
    no, vol, approx, the month abbreviations, U.S, U.K, a.m and p.m, or
    after a single capital initial (J. R. R. Tolkien).
  - It does not end when the next letter is lower case ("Wait… what?"), or
    inside a number (3.5).
  - The end of a block always ends a sentence, so headings and list items are
    their own units.
  - One-word fragments ("Nothing.") join the sentence before them. If the
    fragment starts its paragraph, it joins the sentence after it.
- **Across pages.** Spotlight reads back from the top of the page to the
  start of the paragraph, and past the bottom until the last sentence closes.
  A sentence split by a page break is therefore known as a whole on both
  pages.
- **Cost.** Sentences are worked out for the current page and the next one,
  and cached per page. They are worked out again only when the layout changes
  (font, size, margins, spacing, rotation). Reading text from crengine makes
  it redraw the page on the next paint, so Spotlight only reads text right
  before a page is drawn anyway. It never reads text while stepping between
  sentences.
- **Screen refresh.** Spotlight refreshes only the area of the old and new
  highlight:
  - It uses the "ui" waveform, the fastest one that shows gray cleanly.
    Bar-only and underline styles use "fast" (black and white only), since
    only the bar or the line changes.
  - The night-mode Bright sentence also uses "ui". Its letters have gray
    anti-aliased edges, which "fast" would make jagged.
  - Neither counts toward KOReader's "full refresh every N pages", and page
    turns use KOReader's own refresh, so that setting keeps working as
    before.
- **Off means off.** When Spotlight is off it draws nothing and handles no
  input.
- **The pacer** uses one timer, set for when the lit sentence is due. It is
  cancelled whenever the light pauses: finger down, sleep, the end of the
  book, Manual mode, Spotlight off, or closing the book. If a menu or dialog
  covers the page when the timer fires, it checks again every second. Once
  the menu or dialog closes, the light waits 1 s before moving on.
- **Watching touches.** KOReader passes every gesture to its modules before
  its own touch zones run. Spotlight uses that to watch for finger down
  ("touch", sent at once) and for the end of the contact, without taking
  either. KOReader only reports a hold after 500 ms, which is why the pause
  starts at finger down. Holds are then taken by a Spotlight touch zone
  that has priority over KOReader's highlight and footer holds, in Auto mode
  only.
- **Taps.** Spotlight registers one full-screen tap zone with KOReader. It
  is declared to take priority over KOReader's page-turn taps and its
  tap-on-highlight handler. Its handler declines (KOReader then handles the
  tap) when Spotlight is off, when a text selection is in progress, and for
  taps in KOReader's menu and settings areas. KOReader's link zone already
  has priority over those same zones, so links still win.
- **Page keys.** KOReader's page-turning module handles the page keys before
  any plugin sees them. While Spotlight is on, it sets that module's two
  page-key entries to inactive and handles the same keys itself. Inactive is
  a flag KOReader's own key handling checks. It is cleared as soon as
  Spotlight is off or the book is in scroll mode. No KOReader code is
  replaced.

## Known limits

- Page mode only. In scroll mode Spotlight stays off and says so.
- PDF, DjVu and CBZ are not supported (they are not reflowable).
- Two-page (landscape) mode: the bar for the right page is placed from the
  page margins and has not been checked on a device yet.
- "etc." and the other abbreviations never end a sentence, even when one
  really ends there ("…and so on, etc. Then we left." stays one sentence).
- Saved highlights: while Spotlight is on, tapping one moves the light
  instead of opening the highlight's menu. Turn Spotlight off to open it.
- Right-to-left books: the back zone is always on the left.
- The Paperwhite has no page keys, so key handling has only been tried in
  the Mac app.
- Illustrated editions: an illustration placed in the middle of a paragraph
  splits the sentence around it, and picture captions are lit as sentences.
- Stats count reading with Spotlight on only. Pages read with Spotlight off
  are not in them (KOReader's own Reading statistics plugin covers those).
- If KOReader's footer is hidden and a book has a very small bottom margin,
  the Auto label can sit close to the last line of text.
- Sentences longer than about 200 words that run over a page break may be
  split where the page breaks. The limit is `max_words_back` /
  `max_words_past_page` in `pace.lua`.

## Development

The project folder:

    spotlight/
    ├── README.md
    ├── tests/                  desktop tests (plain LuaJIT)
    │   ├── run.lua             test runner
    │   ├── test_sentences.lua  sentence rules
    │   ├── test_pace.lua       timing rules, pacer, pace model, auto-adjust windows
    │   ├── test_main.lua       main.lua against a fake crengine document
    │   ├── test_manual.lua     Manual mode: taps, keys, pages, timing
    │   ├── test_auto.lua       Auto mode: pacer, holds, skips, page turns, speed
    │   ├── test_learning.lua   learning, "Auto is ready", pace per book, auto-adjust
    │   ├── test_stats.lua      sessions, reading time, periods and trends
    │   ├── test_sessions.lua   sessions recorded while reading, stats screen, export
    │   ├── json_lite.lua       a small JSON library standing in for KOReader's rapidjson
    │   ├── fake_reader.lua     KOReader stubs and the fake document
    │   └── koreader/           end-to-end test in real KOReader (run.sh)
    └── spotlight.koplugin/     the only folder that goes on the Kindle
        ├── _meta.lua
        ├── main.lua            KOReader side: reading pages, drawing, input, menus, events
        ├── speedpanel.lua      the speed panel (KOReader widgets)
        ├── stats.lua           session records and summaries (no KOReader dependencies)
        ├── sentences.lua       sentence boundaries (no KOReader dependencies)
        └── pace.lua            tunable numbers, timings, pacer, pace model, auto-adjust (no KOReader dependencies)

Run the tests from the project folder:

    luajit tests/run.lua

### End-to-end test in real KOReader

`tests/koreader/` runs Spotlight inside the real KOReader, headless, on a
real EPUB:
- The screen is sized like a Paperwhite 5 (1236 × 1648, 300 dpi).
- It sends real tap, hold, swipe and key events.
- It prints PASS or FAIL per check, and saves screenshots.

It needs the KOReader macOS app from the nightly builds (see "Try it on the
Mac first") and any EPUB:

    tests/koreader/run.sh path/to/KOReader.app path/to/book.epub 20

The last number is the page to start on. Nothing is installed: each run
uses a fresh, throwaway KOReader settings folder, and the script prints its
path at the end (screenshots are in `shots/` inside it).

`fake_reader.lua` copies crengine's word-walking rules (from
`crengine/src/lvtinydom.cpp`). That lets the page reading, the cross-page
sentences and the highlight ranges be tested without a Kindle.
