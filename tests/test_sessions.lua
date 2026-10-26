-- M5: session stats recorded by main.lua, the stats screen, export.
local Fake = require("fake_reader")
local Pace = require("pace")
local json = require("json_lite")
local test, eq, ok = T.test, T.eq, T.ok
local cfg = Pace.config

local RIGHT = { x = 450, y = 400 }
local LEFT = { x = 60, y = 400 }
local STATS = "/fake/settings/spotlight_stats.json"

-- One page of 150 sentences of 10 words each.
local function longBook()
    local parts = {}
    for i = 1, 150 do parts[i] = "Word word word word word word word word word word." end
    local doc = Fake.newDoc({ table.concat(parts, " ") }, { { 1, 1 } })
    doc.file = "/books/A Long Book.epub"
    return doc
end

local function open(opts)
    opts = opts or {}
    local plugin = Fake.newPlugin(longBook(), opts)
    plugin.ui.doc_props = { display_title = "A Long Book" }
    if opts.enabled ~= false then plugin:setEnabled(true) end
    return plugin
end

local function tap(plugin, pos)
    pos = pos or RIGHT
    plugin:onGesture({ ges = "touch", pos = pos })
    plugin:onGesture({ ges = "tap", pos = pos })
    return plugin.registered.zones.spotlight_tap.handler({ ges = "tap", pos = pos })
end

local function sessions()
    local text = Fake.files[STATS]
    return text and json.decode(text).sessions or {}
end

test("a Manual session: reading time, sentences, words, pace", function()
    Fake.resetSettings()
    local plugin = open()
    for _i = 1, 10 do
        Fake.advance(3000) -- 10 words in 3 s: 200 wpm
        tap(plugin)
    end
    plugin:onCloseDocument()
    local list = sessions()
    eq(#list, 1)
    local r = list[1]
    eq(r.book_title, "A Long Book")
    eq(r.sentences, 10)
    eq(r.words, 100)
    eq(r.active_seconds, 30)
    eq(r.manual_seconds, 30)
    eq(r.auto_seconds, 0)
    eq(r.average_wpm, 200)
    eq(r.date, os.date("%Y-%m-%d"))
end)

test("gaps over 90 seconds are left out of reading time", function()
    Fake.resetSettings()
    local plugin = open()
    Fake.advance(3000); tap(plugin)
    Fake.advance(5 * 60 * 1000); tap(plugin) -- put down for 5 minutes
    Fake.advance(3000); tap(plugin)
    plugin:onCloseDocument()
    eq(sessions()[1].active_seconds, 6)
    eq(sessions()[1].sentences, 3)
end)

test("an Auto session: time in each mode, holds, skips, backs, pace and adjustments", function()
    Fake.resetSettings()
    Fake.seedLearned(200, 400)
    local plugin = open()
    Fake.advance(3000); tap(plugin)           -- 3 s of Manual reading
    plugin:setMode("auto")                    -- 200 wpm, 400 ms pause
    local due = function() return plugin.pacer:untilDue(Fake.clock_ms) end
    Fake.advance(due())                       -- start grace + first sentence
    tap(plugin, RIGHT)                        -- a skip-ahead
    plugin:onGesture({ ges = "touch", pos = RIGHT })
    plugin.registered.zones.spotlight_hold.handler({ ges = "hold", pos = RIGHT })
    Fake.advance(2000)
    plugin:onGesture({ ges = "hold_release", pos = RIGHT })
    Fake.advance(1000)
    tap(plugin, LEFT)                         -- a back
    -- The skip, hold and back fall in the first window of 15 (2 stops: no
    -- change); the next two windows are quiet: one +2 % change.
    for _i = 1, 45 do Fake.advance(due()) end
    plugin:onCloseDocument()
    local r = sessions()[1]
    eq(r.manual_seconds, 3)
    ok(r.auto_seconds > 60, "auto seconds " .. r.auto_seconds)
    eq(r.active_seconds, r.manual_seconds + r.auto_seconds)
    eq({ r.holds, r.skip_aheads, r.backs }, { 1, 1, 1 })
    eq(r.starting_pace_wpm, 200)
    eq(r.auto_adjust_changes, 1)
    eq(r.ending_pace_wpm, 204)
end)

test("the session is saved when the Kindle sleeps, and replaced when it goes on", function()
    Fake.resetSettings()
    local plugin = open()
    Fake.advance(3000); tap(plugin)
    plugin:onSuspend()
    eq(#sessions(), 1)
    eq(sessions()[1].sentences, 1)
    plugin:onResume()                          -- a short sleep: same session
    Fake.advance(3000); tap(plugin)
    plugin:onCloseDocument()
    eq(#sessions(), 1)
    eq(sessions()[1].sentences, 2)
end)

test("after a long sleep the next reading is a new session", function()
    Fake.resetSettings()
    local plugin = open()
    Fake.advance(3000); tap(plugin)
    plugin:onSuspend()
    plugin.stats_session.last_at = os.time() - cfg.session_break_s - 60 -- slept 31 minutes
    plugin:onResume()
    Fake.advance(3000); tap(plugin)
    Fake.advance(3000); tap(plugin)
    plugin:onCloseDocument()
    local list = sessions()
    eq(#list, 2)
    eq(list[2].sentences, 2)
end)

test("nothing recorded while Spotlight is off", function()
    Fake.resetSettings()
    local plugin = open({ enabled = false })
    Fake.advance(60000)
    plugin:onCloseDocument()
    eq(Fake.files[STATS], nil)
end)

test("the file uses plain field names and describes them", function()
    Fake.resetSettings()
    local plugin = open()
    Fake.advance(3000); tap(plugin)
    plugin:onCloseDocument()
    local data = json.decode(Fake.files[STATS])
    eq(data.format, "spotlight-sessions")
    eq(data.version, 1)
    eq(data.fields.active_seconds, "reading time; gaps over 90 seconds are left out")
    ok(Fake.files[STATS]:find('\n  "sessions": %['), "pretty-printed")
end)

-- Stats screen ------------------------------------------------------------------

local function today(n)
    return os.date("%Y-%m-%d", os.time() - (n or 0) * 86400)
end

test("the stats screen: today, 7 days, 30 days, with trends", function()
    Fake.resetSettings()
    -- Yesterday: 10 minutes, 100 sentences, 1800 words (180 wpm), 6 stops.
    Fake.files[STATS] = json.encode({ sessions = json.array({
        { id = "y", date = today(1), active_seconds = 600, sentences = 100, words = 1800, holds = 3, backs = 3 },
    }) })
    local plugin = open()
    -- Today: 20 sentences of 10 words in 60 s (200 wpm), one back.
    for _i = 1, 20 do Fake.advance(3000); tap(plugin) end
    tap(plugin, LEFT)
    Fake.shown = {}
    plugin:onSpotlightStats()
    local page = Fake.shown[1]
    ok(page and page.kv, "a KeyValuePage")
    eq(page.title, "Spotlight stats")
    local rows = {}
    for _i, r in ipairs(page.kv_pairs) do
        if type(r) == "table" then rows[#rows + 1] = r[1] .. " = " .. r[2] end
    end
    eq(rows[1], "Today (trend vs yesterday) = ")
    eq(rows[2], "Minutes read = 1")
    eq(rows[3], "Sentences = 20")
    eq(rows[4], "Average pace = 200 wpm  (+20)")
    eq(rows[5], "Stops per 100 sentences = 5.0  (−1.0)")
    eq(rows[6], "Last 7 days (trend vs the 7 days before) = ")
    eq(rows[9], "Average pace = 182 wpm")   -- 2000 words in 660 s; nothing the week before: no trend
    eq(rows[#rows], "Stops are holds and backs. = ")
end)

test("a period without reading shows dashes", function()
    Fake.resetSettings()
    local plugin = open()
    local rows = plugin:statsRows(require("stats").report({}, today()))
    eq(rows[4][2], "–")
    eq(rows[5][2], "–")
end)

-- Export ----------------------------------------------------------------------

test("export copies the sessions to <home>/spotlight/spotlight_stats.json", function()
    Fake.resetSettings()
    local plugin = open()
    Fake.advance(3000); tap(plugin)
    Fake.shown = {}
    local done, path = plugin:exportStats()
    ok(done)
    eq(path, "/fake/home/spotlight/spotlight_stats.json")
    ok(Fake.dirs["/fake/home/spotlight"])
    local data = json.decode(Fake.files[path])
    eq(#data.sessions, 1) -- the session in progress is included
    eq(Fake.shown[1].text, "Exported 1 sessions to\n" .. path)
end)

test("export says so when it cannot write", function()
    Fake.resetSettings()
    local plugin = open()
    Fake.unwritable = "/fake/home"
    Fake.shown = {}
    ok(not plugin:exportStats())
    ok(Fake.shown[1].text:find("^Could not write"))
end)

test("Stats is in the menu, with Show and Export", function()
    Fake.resetSettings()
    local plugin = open()
    local items = {}
    plugin:addToMainMenu(items)
    local stats
    for _i, item in ipairs(items.spotlight.sub_item_table) do
        if item.text == "Stats" then stats = item end
    end
    eq(stats.sub_item_table[1].text, "Show stats")
    eq(stats.sub_item_table[2].text, "Export stats (JSON)")
end)
