-- M3, Auto mode (the pacer): main.lua driven by a fake crengine document and
-- a clock the test moves by hand (see fake_reader.lua).
local Fake = require("fake_reader")
local Pace = require("pace")
local test, eq, ok = T.test, T.eq, T.ok
local cfg = Pace.config

local PARAS = {
    "Chapter One",
    "It was a dark night. Mr. Smith walked home slowly. The rain kept falling on the old town, and he "
        .. "thought about “the letter.” Nothing. She was gone.",
    "“Go now,” she said. He left at once.",
}
local PAGES = { { 1, 1 }, { 2, 21 }, { 3, 1 } }
local RIGHT = { x = 450, y = 400 }
local LEFT = { x = 60, y = 400 }
local MS_PER_WORD = 60000 / cfg.default_wpm -- 300 ms at 200 wpm

-- A plugin with Spotlight on and Auto started (not waiting for a tap).
local function setup(opts)
    opts = opts or {}
    Fake.resetSettings()
    Fake.seedLearned(cfg.default_wpm, cfg.sentence_pause_ms)
    local doc = Fake.newDoc(PARAS, PAGES)
    doc.cur = opts.page or 1
    local plugin = Fake.newPlugin(doc, opts)
    plugin:setEnabled(true)
    if opts.mode ~= "manual" then plugin:setMode("auto") end
    return plugin, doc
end

local function lit(plugin)
    local s = plugin:currentSentence()
    return s and s.text
end
local function due(plugin) return plugin.pacer:untilDue(Fake.clock_ms) end
local function gesture(plugin, name, pos) return plugin:onGesture({ ges = name, pos = pos or RIGHT }) end
local function zone(plugin, id, name, pos)
    return plugin.registered.zones[id].handler({ ges = name, pos = pos or RIGHT })
end
-- A quick tap as KOReader delivers it: finger down, then the tap.
local function tap(plugin, pos)
    gesture(plugin, "touch", pos)
    gesture(plugin, "tap", pos)
    return zone(plugin, "spotlight_tap", "tap", pos)
end

test("the light moves on its own at the set speed", function()
    local plugin = setup()
    eq(lit(plugin), "Chapter One")
    -- First sentence after starting: pause + 2 words + the start grace.
    eq(due(plugin), cfg.sentence_pause_ms + 2 * MS_PER_WORD + cfg.page_turn_grace_ms)
    Fake.advance(due(plugin))
    eq(lit(plugin), "It was a dark night.")
    -- Next one on the same page: pause + 5 words, no grace.
    eq(due(plugin), cfg.sentence_pause_ms + 5 * MS_PER_WORD)
    Fake.advance(due(plugin) - 1)
    eq(lit(plugin), "It was a dark night.")
    Fake.advance(1)
    eq(lit(plugin), "Mr. Smith walked home slowly.")
end)

test("each automatic step refreshes only the sentence area", function()
    local plugin = setup()
    plugin:paintTo(Fake.newCanvas(), 0, 0)
    local before = #Fake.dirty
    Fake.advance(due(plugin))
    local d = Fake.dirty[before + 1]
    eq(d.mode, "ui")
    ok(d.region.h < 100)
end)

test("one timer at a time", function()
    local plugin = setup()
    eq(Fake.pendingTasks(), 1)
    Fake.advance(due(plugin))
    eq(Fake.pendingTasks(), 1)
    tap(plugin, RIGHT)
    eq(Fake.pendingTasks(), 1)
end)

test("hold: paused while the finger is down, then the time left plus 0.5 s", function()
    local plugin = setup()
    Fake.advance(due(plugin))                  -- "It was a dark night." lit
    local total = due(plugin)
    Fake.advance(1000)
    gesture(plugin, "touch")                   -- finger down: pause at once
    eq(Fake.pendingTasks(), 0)
    ok(zone(plugin, "spotlight_hold", "hold"))  -- the hold is taken: no dictionary
    ok(zone(plugin, "spotlight_hold_pan", "hold_pan"))
    Fake.advance(60000)                        -- a long hold
    eq(lit(plugin), "It was a dark night.")
    ok(zone(plugin, "spotlight_hold_release", "hold_release"))
    gesture(plugin, "hold_release")            -- let go
    eq(due(plugin), total - 1000 + cfg.hold_resume_grace_ms)
    Fake.advance(due(plugin))
    eq(lit(plugin), "Mr. Smith walked home slowly.")
    eq(plugin.session.holds, 1)
end)

test("in Manual mode holds are KOReader's (dictionary, highlighting)", function()
    local plugin = setup({ mode = "manual" })
    eq(zone(plugin, "spotlight_hold", "hold"), nil)
    eq(zone(plugin, "spotlight_hold_release", "hold_release"), nil)
    gesture(plugin, "touch")
    eq(Fake.pendingTasks(), 0)                 -- no pacer in Manual mode
end)

test("quick tap right: skip ahead now, and keep going from there", function()
    local plugin = setup()
    Fake.advance(500)
    ok(tap(plugin, RIGHT))
    eq(lit(plugin), "It was a dark night.")
    eq(due(plugin), cfg.sentence_pause_ms + 5 * MS_PER_WORD) -- a fresh, full time
    eq(plugin.session.skips, 1)
    Fake.advance(due(plugin))
    eq(lit(plugin), "Mr. Smith walked home slowly.")
end)

test("quick tap left: back one sentence, and keep going from there", function()
    local plugin = setup()
    Fake.advance(due(plugin))
    Fake.advance(due(plugin))                  -- now on "Mr. Smith..."
    Fake.advance(1000)
    ok(tap(plugin, LEFT))
    eq(lit(plugin), "It was a dark night.")
    eq(plugin.session.backs, 1)
    Fake.advance(due(plugin))
    eq(lit(plugin), "Mr. Smith walked home slowly.")
end)

test("a finger landing just after the light moved goes back to the sentence it aimed at", function()
    local plugin = setup()
    Fake.advance(due(plugin))                  -- the light moves to "It was a dark night."
    Fake.advance(100)                          -- the finger lands 0.1 s later
    gesture(plugin, "touch")
    eq(lit(plugin), "Chapter One")
    ok(plugin.pacer:isPaused())
end)

test("a finger landing well after the light moved stays on the new sentence", function()
    local plugin = setup()
    Fake.advance(due(plugin))
    Fake.advance(cfg.touch_race_ms + 50)
    gesture(plugin, "touch")
    eq(lit(plugin), "It was a dark night.")
end)

test("automatic page turn: the split sentence continues, with the 0.8 s grace", function()
    local plugin, doc = setup()
    Fake.advance(due(plugin))
    Fake.advance(due(plugin))
    Fake.advance(due(plugin))                  -- the sentence split by the page break
    ok(plugin:currentSentence().ends_after)
    -- Its first part gets its share of the time: 10 of its 15 words.
    eq(due(plugin), cfg.sentence_pause_ms + 10 * MS_PER_WORD)
    Fake.advance(due(plugin))
    eq(doc.cur, 2)
    ok(plugin:currentSentence().starts_before)
    -- The rest: 5 words, no second pause, plus the page-turn grace.
    eq(due(plugin), 5 * MS_PER_WORD + cfg.page_turn_grace_ms)
    Fake.advance(due(plugin))
    eq(lit(plugin), "She was gone.")
    Fake.advance(due(plugin))
    eq(doc.cur, 3)
    eq(lit(plugin), "“Go now,” she said.")
    eq(due(plugin), cfg.sentence_pause_ms + 4 * MS_PER_WORD + cfg.page_turn_grace_ms)
end)

test("a swipe in Auto mode turns the page and the light carries on there", function()
    local plugin, doc = setup()
    gesture(plugin, "touch")
    gesture(plugin, "swipe")
    doc.cur = 3
    plugin:onPageUpdate(3)
    eq(lit(plugin), "“Go now,” she said.")
    ok(plugin.pacer:isRunning())
end)

test("a menu or dialog over the page holds the light until it closes", function()
    local plugin = setup()
    Fake.top_widget = { name = "TouchMenu" }
    Fake.advance(due(plugin) + 5000)
    eq(lit(plugin), "Chapter One")
    Fake.top_widget = nil
    Fake.advance(cfg.blocked_poll_s * 1000)    -- noticed it closed: a moment to look
    eq(lit(plugin), "Chapter One")
    Fake.advance(cfg.dialog_resume_grace_ms)
    eq(lit(plugin), "It was a dark night.")
end)

test("sleep pauses; after waking, the first tap starts the light again", function()
    local plugin = setup()
    plugin:onSuspend()
    eq(Fake.pendingTasks(), 0)
    plugin:onResume()
    Fake.advance(60000)
    eq(lit(plugin), "Chapter One")
    ok(tap(plugin, RIGHT))                     -- starts, does not skip
    eq(lit(plugin), "Chapter One")
    ok(plugin.pacer:isRunning())
end)

test("a book opened in Auto mode waits for the first tap", function()
    Fake.resetSettings()
    Fake.seedLearned(cfg.default_wpm, cfg.sentence_pause_ms)
    local doc = Fake.newDoc(PARAS, PAGES)
    local first = Fake.newPlugin(doc)
    first:setEnabled(true)
    first:setMode("auto")
    first:onCloseDocument()
    local plugin = Fake.newPlugin(Fake.newDoc(PARAS, PAGES)) -- same settings: on, Auto
    ok(plugin:isAuto())
    Fake.advance(60000)
    eq(lit(plugin), "Chapter One")
    tap(plugin, RIGHT)
    eq(lit(plugin), "Chapter One")
    Fake.advance(due(plugin))
    eq(lit(plugin), "It was a dark night.")
end)

test("speed: Faster and Slower in steps of 5, kept between 80 and 400", function()
    local plugin = setup()
    plugin:onSpotlightFaster()
    eq(plugin:paceWpm(), cfg.default_wpm + 5)
    plugin:onSpotlightSlower()
    plugin:onSpotlightSlower()
    eq(plugin:paceWpm(), cfg.default_wpm - 5)
    plugin:setWpm(10)
    eq(plugin:paceWpm(), cfg.min_wpm)
    plugin:setWpm(1000)
    eq(plugin:paceWpm(), cfg.max_wpm)
end)

test("a speed change stretches the time left on the lit sentence", function()
    local plugin = setup()
    Fake.advance(due(plugin))                  -- 1900 ms for "It was a dark night."
    Fake.advance(900)                          -- 1000 ms left at 200 wpm
    plugin:setWpm(400)
    eq(due(plugin), 500)
end)

test("indicator: in the footer when it shows all items, otherwise a small label", function()
    local plugin = setup()
    eq(plugin.view.footer:text(), "Auto · 200 wpm")
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    local label
    for _i, op in ipairs(canvas.ops) do if op[1] == "text" then label = op end end
    ok(label, "own label drawn (footer shows one item at a time)")
    eq(label[4], "Auto · 200 wpm")
    ok(label[2] > 300 and label[3] > 700, "bottom-right corner")
    plugin:onSpotlightFaster()
    eq(plugin.view.footer:text(), "Auto · 205 wpm")
end)

test("indicator: no own label when the footer shows all items at once", function()
    local plugin = setup({ footer_all_at_once = true })
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    for _i, op in ipairs(canvas.ops) do ok(op[1] ~= "text") end
    eq(plugin.view.footer:text(), "Auto · 200 wpm")
end)

test("indicator: gone in Manual mode", function()
    local plugin = setup()
    plugin:setMode("manual")
    eq(plugin.view.footer:text(), "")
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    for _i, op in ipairs(canvas.ops) do ok(op[1] ~= "text") end
end)

test("while Auto runs, auto-suspend is held off; paused, it is not", function()
    local plugin = setup()
    ok(Fake.plugin_share.pause_auto_suspend)
    gesture(plugin, "touch")
    eq(Fake.plugin_share.pause_auto_suspend, nil)
    gesture(plugin, "hold_release")
    ok(Fake.plugin_share.pause_auto_suspend)
    plugin:setMode("manual")
    eq(Fake.plugin_share.pause_auto_suspend, nil)
end)

test("another plugin's keep-alive setting is left as it was", function()
    Fake.resetSettings()
    Fake.seedLearned()
    Fake.plugin_share.pause_auto_suspend = true -- e.g. the Keep-alive plugin
    local doc = Fake.newDoc(PARAS, PAGES)
    local plugin = Fake.newPlugin(doc)
    plugin:setEnabled(true)
    plugin:setMode("auto")
    plugin:setMode("manual")
    eq(Fake.plugin_share.pause_auto_suspend, true)
end)

-- A long book: one page of 150 eleven-word sentences (about 9 minutes at 200 wpm).
local function longBook()
    local parts = {}
    for i = 1, 150 do parts[i] = "This is sentence number " .. i .. " of a fairly long chapter here." end
    return Fake.newDoc({ table.concat(parts, " ") }, { { 1, 1 } })
end

test("Kindle: the power manager is told the reader is in use every 5 minutes", function()
    Fake.resetSettings()
    Fake.seedLearned()
    Fake.is_kindle = true
    local plugin = Fake.newPlugin(longBook())
    plugin:setEnabled(true)
    plugin:setMode("auto")
    eq(Fake.powerd.t1_resets, 1)              -- at start
    Fake.advance(cfg.keep_awake_every_s * 1000 - 5000)
    eq(Fake.powerd.t1_resets, 1)
    Fake.advance(10000)
    eq(Fake.powerd.t1_resets, 2)              -- 5 minutes later
end)

test("the end of the book: the light stops and waits", function()
    local plugin, doc = setup({ page = 3 })
    Fake.advance(due(plugin))
    eq(lit(plugin), "He left at once.")
    Fake.advance(due(plugin))
    eq(lit(plugin), "He left at once.")
    eq(Fake.pendingTasks(), 0)
    ok(plugin.pause_reasons["end"])
    tap(plugin, LEFT)                          -- going back starts it again
    eq(lit(plugin), "“Go now,” she said.")
    ok(plugin.pacer:isRunning())
end)

test("Manual mode, Spotlight off and closing the book stop the timer", function()
    local plugin = setup()
    plugin:setMode("manual")
    eq(Fake.pendingTasks(), 0)
    plugin:setMode("auto")
    eq(Fake.pendingTasks(), 1)
    plugin:setEnabled(false)
    eq(Fake.pendingTasks(), 0)
    plugin:setEnabled(true)
    eq(Fake.pendingTasks(), 1)
    plugin:onCloseDocument()
    eq(Fake.pendingTasks(), 0)
    eq(#plugin.view.footer.contents, 0)
end)

test("no reading timings are taken in Auto mode", function()
    local plugin = setup()
    for _i = 1, 3 do Fake.advance(due(plugin)) end
    eq(#plugin.samples, 0)
end)

test("gesture action Toggle Auto turns Spotlight on if needed", function()
    Fake.resetSettings()
    Fake.seedLearned()
    local plugin = Fake.newPlugin(Fake.newDoc(PARAS, PAGES))
    plugin:onSpotlightToggleAuto()
    ok(plugin.settings.enabled)
    ok(plugin:isAuto())
    plugin:onSpotlightToggleAuto()
    eq(plugin.settings.mode, "manual")
end)

test("page keys in Auto mode skip and go back like taps", function()
    local plugin = setup()
    ok(plugin:onKeyPress(Fake.key("RPgFwd")))
    eq(lit(plugin), "It was a dark night.")
    ok(plugin:onKeyPress(Fake.key("LPgBack")))
    eq(lit(plugin), "Chapter One")
end)
