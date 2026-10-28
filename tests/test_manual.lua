-- M2, Manual mode: taps, keys, crossing pages, per-book position, timing.
-- main.lua driven by a fake crengine document (see fake_reader.lua).
local Fake = require("fake_reader")
local test, eq, ok = T.test, T.eq, T.ok

local PARAS = {
    "Chapter One",
    "It was a dark night. Mr. Smith walked home slowly. The rain kept falling on the old town, and he "
        .. "thought about “the letter.” Nothing. She was gone.",
    "“Go now,” she said. He left at once.",
}
-- Page 1: "Chapter" to "he"; page 2 from "thought"; page 3 from "“Go".
local PAGES = { { 1, 1 }, { 2, 21 }, { 3, 1 } }
local CROSSING = "The rain kept falling on the old town, and he thought about “the letter.” Nothing."

-- Screen is 600 x 800 in the fake.
local RIGHT = { x = 450, y = 400 }
local LEFT = { x = 60, y = 400 }

local function setup(opts)
    opts = opts or {}
    Fake.resetSettings()
    Fake.clock_ms = 0
    local doc = Fake.newDoc(PARAS, PAGES)
    doc.cur = opts.page or 1
    local plugin = Fake.newPlugin(doc, opts)
    if opts.enabled ~= false then plugin:setEnabled(true) end
    return plugin, doc
end

local function tap(plugin, pos)
    return plugin.registered.zones.spotlight_tap.handler({ pos = pos })
end

local function lit(plugin)
    local s = plugin:currentSentence()
    return s and s.text
end

test("the tap zone takes priority over page turns and highlight taps", function()
    local plugin = setup()
    local zone = plugin.registered.zones.spotlight_tap
    eq(zone.ges, "tap")
    eq(zone.overrides, { "tap_forward", "tap_backward", "readerhighlight_tap" })
end)

test("tap right or middle: next sentence; tap left quarter: previous", function()
    local plugin = setup()
    eq(lit(plugin), "Chapter One")
    ok(tap(plugin, RIGHT))
    eq(lit(plugin), "It was a dark night.")
    ok(tap(plugin, { x = 300, y = 500 })) -- middle
    eq(lit(plugin), "Mr. Smith walked home slowly.")
    ok(tap(plugin, LEFT))
    eq(lit(plugin), "It was a dark night.")
end)

test("stepping on the same page refreshes only the highlight area", function()
    local plugin = setup()
    plugin:paintTo(Fake.newCanvas(), 0, 0)
    local before = #Fake.dirty
    tap(plugin, RIGHT)
    eq(#Fake.dirty, before + 1)
    local d = Fake.dirty[#Fake.dirty]
    eq(d.mode, "ui")
    eq(d.widget, "reader-dialog")
    ok(d.region.h < 100, "only the old and new sentence lines")
    eq(#plugin.ui.page_turns, 0)
end)

test("taps in KOReader's menu and settings areas are left to KOReader", function()
    local plugin = setup()
    eq(tap(plugin, { x = 450, y = 50 }), nil)   -- top menu band
    eq(tap(plugin, { x = 300, y = 140 }), nil)  -- taller menu area in the middle
    eq(tap(plugin, { x = 450, y = 780 }), nil)  -- bottom settings bar
    eq(tap(plugin, { x = 300, y = 680 }), nil)  -- taller settings area in the middle
    eq(lit(plugin), "Chapter One")
end)

test("when Spotlight is off, taps are KOReader's", function()
    local plugin = setup({ enabled = false })
    eq(tap(plugin, RIGHT), nil)
    eq(tap(plugin, LEFT), nil)
end)

test("a tap during a text selection is left to KOReader", function()
    local plugin = setup()
    plugin.ui.highlight.hold_pos = { x = 1, y = 1 }
    eq(tap(plugin, RIGHT), nil)
end)

test("forward across pages: the split sentence continues on the next page", function()
    local plugin, doc = setup()
    for _ = 1, 3 do tap(plugin, RIGHT) end
    eq(lit(plugin), CROSSING)
    eq(doc.cur, 1)
    tap(plugin, RIGHT) -- the rest of the same sentence, on page 2
    eq(doc.cur, 2)
    eq(lit(plugin), CROSSING)
    ok(plugin:currentSentence().starts_before)
    tap(plugin, RIGHT)
    eq(lit(plugin), "She was gone.")
    tap(plugin, RIGHT) -- last sentence on page 2: turn, first sentence of page 3
    eq(doc.cur, 3)
    eq(lit(plugin), "“Go now,” she said.")
    eq(plugin.ui.page_turns, { 1, 1 })
end)

test("backward across pages", function()
    local plugin, doc = setup({ page = 3 })
    eq(lit(plugin), "“Go now,” she said.")
    tap(plugin, LEFT) -- previous page, its last sentence
    eq(doc.cur, 2)
    eq(lit(plugin), "She was gone.")
    tap(plugin, LEFT)
    eq(lit(plugin), CROSSING)
    eq(doc.cur, 2)
    tap(plugin, LEFT) -- the beginning of the same sentence, on page 1
    eq(doc.cur, 1)
    eq(lit(plugin), CROSSING)
    ok(plugin:currentSentence().ends_after)
    tap(plugin, LEFT)
    eq(lit(plugin), "Mr. Smith walked home slowly.")
end)

test("back on the first sentence of the book stays put", function()
    local plugin, doc = setup()
    tap(plugin, LEFT)
    eq(doc.cur, 1)
    eq(lit(plugin), "Chapter One")
end)

test("a swipe (any other page turn) lights the first sentence on the new page", function()
    local plugin, doc = setup()
    doc.cur = 3
    plugin:onPageUpdate(3)
    eq(lit(plugin), "“Go now,” she said.")
end)

test("page keys: taken over while Spotlight is on, given back when off", function()
    local plugin = setup()
    local ke = plugin.ui.rolling.key_events
    ok(ke.GotoNextView.is_inactive)
    ok(ke.GotoPrevView.is_inactive)
    ok(plugin:onKeyPress(Fake.key("RPgFwd")))
    eq(lit(plugin), "It was a dark night.")
    ok(plugin:onKeyPress(Fake.key("LPgBack")))
    eq(lit(plugin), "Chapter One")
    eq(plugin:onKeyPress(Fake.key("Home")), nil) -- other keys pass through
    plugin:setEnabled(false)
    eq(ke.GotoNextView.is_inactive, nil)
    eq(ke.GotoPrevView.is_inactive, nil)
    eq(plugin:onKeyPress(Fake.key("RPgFwd")), nil)
end)

test("page keys are given back in scroll mode", function()
    local plugin = setup()
    plugin.view.view_mode = "scroll"
    plugin:onChangeViewMode()
    eq(plugin.ui.rolling.key_events.GotoNextView.is_inactive, nil)
    eq(tap(plugin, RIGHT), nil)
end)

test("the sentence is saved per book and restored on open", function()
    local plugin, doc = setup()
    tap(plugin, RIGHT)
    tap(plugin, RIGHT)
    plugin:onSaveSettings()
    local saved = plugin.ui.doc_settings.data.spotlight_position
    ok(saved ~= nil)
    -- Open the book again: KOReader restores the page, Spotlight the sentence.
    local doc2 = Fake.newDoc(PARAS, PAGES)
    doc2.cur = doc.cur
    local again = Fake.newPlugin(doc2, { doc_settings = { spotlight_position = saved } })
    eq(lit(again), "Mr. Smith walked home slowly.")
end)

test("a saved sentence on another page falls back to the first on the page", function()
    local plugin = setup()
    tap(plugin, RIGHT)
    plugin:onSaveSettings()
    local saved = plugin.ui.doc_settings.data.spotlight_position
    local doc2 = Fake.newDoc(PARAS, PAGES)
    doc2.cur = 3
    local again = Fake.newPlugin(doc2, { doc_settings = { spotlight_position = saved } })
    eq(lit(again), "“Go now,” she said.")
end)

test("a layout change keeps the same sentence lit", function()
    local plugin = setup()
    tap(plugin, RIGHT)
    tap(plugin, RIGHT)
    -- ReaderRolling after a font change: PageUpdate, then DocumentRerendered.
    plugin:onPageUpdate(1)
    plugin:onDocumentRerendered()
    eq(lit(plugin), "Mr. Smith walked home slowly.")
end)

-- Timing -------------------------------------------------------------------

local function samples(plugin) return plugin.samples end

test("each sentence is timed; clean timings are kept", function()
    local plugin = setup()
    tap(plugin, RIGHT)                -- "It was a dark night." lit (5 words)
    Fake.advance(2500)                -- 500 ms per word
    tap(plugin, RIGHT)
    eq(#samples(plugin), 1)
    eq(samples(plugin)[1].words, 5)
    eq(samples(plugin)[1].ms, 2500)
end)

test("the first sentence after opening or a page turn is not kept", function()
    local plugin, doc = setup()
    Fake.advance(2000)                -- "Chapter One" lit on open
    tap(plugin, RIGHT)
    eq(#samples(plugin), 0)
    doc.cur = 3
    plugin:onPageUpdate(3)            -- swipe
    Fake.advance(2000)
    tap(plugin, RIGHT)
    eq(#samples(plugin), 0)
end)

test("a reread sentence is not kept", function()
    local plugin = setup()
    tap(plugin, RIGHT)                -- "It was a dark night."
    Fake.advance(2500)
    tap(plugin, RIGHT)                -- kept
    tap(plugin, LEFT)                 -- back to "It was a dark night."
    Fake.advance(2500)
    tap(plugin, RIGHT)                -- reread: skipped
    eq(#samples(plugin), 1)
end)

test("a sentence split by a page break is timed as one, and not kept", function()
    local plugin = setup()
    tap(plugin, RIGHT); Fake.advance(2500)
    tap(plugin, RIGHT); Fake.advance(3000)
    tap(plugin, RIGHT)                -- the split sentence, lit at t
    eq(#samples(plugin), 2)
    Fake.advance(4000)
    tap(plugin, RIGHT)                -- its rest, on page 2: same clock
    ok(plugin.timing.after_turn)
    Fake.advance(4000)
    local sample, kept = plugin:finishTiming()
    eq(sample.ms, 8000)
    ok(not kept)
end)

test("too fast or too slow timings are not kept", function()
    local plugin = setup()
    tap(plugin, RIGHT)
    Fake.advance(300)                 -- 60 ms per word
    tap(plugin, RIGHT)
    eq(#samples(plugin), 0)
end)

test("sleep stops the clock", function()
    local plugin = setup()
    tap(plugin, RIGHT)
    Fake.advance(1000)
    plugin:onSuspend()
    Fake.advance(600000)
    plugin:onResume()
    ok(plugin.timing.after_turn)
end)

test("kept timings are saved in Spotlight's own settings file", function()
    local plugin = setup()
    tap(plugin, RIGHT)
    Fake.advance(2500)
    tap(plugin, RIGHT)
    plugin:onSaveSettings()
    local file = Fake.store_files["/fake/settings/spotlight.lua"]
    eq(#file.data.manual_samples, 1)
    eq(file.flushes, 1)
    plugin:onSaveSettings() -- nothing new: no write
    eq(file.flushes, 1)
end)

test("gesture actions: next and previous sentence", function()
    local plugin = setup()
    ok(plugin:onSpotlightNext())
    eq(lit(plugin), "It was a dark night.")
    ok(plugin:onSpotlightPrev())
    eq(lit(plugin), "Chapter One")
end)

test("a repeated page-shown event keeps the lit sentence (restore after open)", function()
    local plugin = setup()
    tap(plugin, RIGHT)
    tap(plugin, RIGHT)
    plugin:onPageUpdate(1) -- KOReader redraws the same page
    eq(lit(plugin), "Mr. Smith walked home slowly.")
end)

-- Invert taps ------------------------------------------------------------------

-- Screen is 600 px wide: the back zone is 150 px (a quarter).
local FAR_LEFT = { x = 60, y = 400 }
local MIDDLE = { x = 300, y = 400 }
local FAR_RIGHT = { x = 550, y = 400 }

local function invertItem(plugin)
    local items = {}
    plugin:addToMainMenu(items)
    for _i, item in ipairs(items.spotlight.sub_item_table) do
        if item.text_func and item.text_func():find("^Invert taps") then return item end
    end
end

test("Invert taps: forward on the left three quarters, back on the right quarter", function()
    local plugin = setup()
    invertItem(plugin).callback()
    ok(plugin.settings.invert_taps)
    tap(plugin, FAR_LEFT)
    eq(lit(plugin), "It was a dark night.")
    tap(plugin, MIDDLE)
    eq(lit(plugin), "Mr. Smith walked home slowly.")
    tap(plugin, FAR_RIGHT)
    eq(lit(plugin), "It was a dark night.")
    invertItem(plugin).callback() -- and back to normal
    tap(plugin, FAR_LEFT)
    eq(lit(plugin), "Chapter One")
end)

test("Invert taps also turns Auto's skip and back around", function()
    Fake.resetSettings()
    Fake.seedLearned()
    local doc = Fake.newDoc(PARAS, PAGES)
    local plugin = Fake.newPlugin(doc)
    plugin:setEnabled(true)
    plugin.settings.invert_taps = true
    plugin:setMode("auto")
    tap(plugin, FAR_LEFT)                      -- skip ahead
    eq(lit(plugin), "It was a dark night.")
    eq(plugin.session.skips, 1)
    Fake.advance(1000)
    tap(plugin, FAR_RIGHT)                     -- back
    eq(lit(plugin), "Chapter One")
    eq(plugin.session.backs, 1)
end)

test("KOReader's own inverted page turns invert Spotlight's taps too", function()
    local plugin = setup()
    plugin.view.inverse_reading_order = true   -- e.g. a right-to-left book
    ok(plugin:tapsInverted())
    tap(plugin, FAR_LEFT)
    eq(lit(plugin), "It was a dark night.")
    local item = invertItem(plugin)
    ok(item.checked_func() and not item.enabled_func())
    eq(item.text_func(), "Invert taps (on: KOReader's page turn taps are inverted)")
end)

test("a mirrored (right-to-left) KOReader interface counts as inverted, like KOReader's own zones", function()
    local plugin = setup()
    Fake.mirrored_ui = true
    ok(plugin:tapsInverted())
    plugin.view.inverse_reading_order = true    -- inverted twice: back to normal, as in KOReader
    ok(not plugin:tapsInverted())
    Fake.mirrored_ui = false
end)
