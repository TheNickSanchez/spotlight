-- M4: learning your pace, "Auto is ready", pace per book, auto-adjust,
-- the session summary. main.lua driven by the fake reader, with a simulated
-- reader tapping through a long book at a known pace.
local Fake = require("fake_reader")
local Pace = require("pace")
local test, eq, ok = T.test, T.eq, T.ok
local cfg = Pace.config

local RIGHT = { x = 450, y = 400 }

-- One page of 150 sentences of varied length (5 to 29 words).
local function longBook()
    local parts = {}
    for i = 1, 150 do
        local n = 5 + (i * 7) % 25
        local words = {}
        for w = 1, n do words[w] = (w == 1) and "Word" or "word" end
        parts[i] = table.concat(words, " ") .. "."
    end
    return Fake.newDoc({ table.concat(parts, " ") }, { { 1, 1 } })
end

local function newPlugin(opts)
    opts = opts or {}
    local plugin = Fake.newPlugin(opts.doc or longBook(), opts)
    plugin:setEnabled(true)
    return plugin
end

local function tap(plugin)
    plugin:onGesture({ ges = "touch", pos = RIGHT })
    plugin:onGesture({ ges = "tap", pos = RIGHT })
    return plugin.registered.zones.spotlight_tap.handler({ ges = "tap", pos = RIGHT })
end

-- A steady reader: 0.5 s per sentence plus 280 ms a word (about 214 wpm),
-- give or take 10 %. Taps through `n` sentences.
local seed = 11
local function rand()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end
local function read(plugin, n, pause_ms, ms_per_word)
    for _i = 1, n do
        local s = plugin:currentSentence()
        local ms = (pause_ms or 500) + s.words * (ms_per_word or 280)
        Fake.advance(math.floor(ms * (0.9 + rand() * 0.2)))
        tap(plugin)
        if Fake.lastConfirm() then return end -- the popup is up
    end
end

local function infoTexts()
    local t = {}
    for _i, w in ipairs(Fake.shown) do if w.text then t[#t + 1] = w.text end end
    return t
end

test("choosing Auto the first time starts learning in Manual mode", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    eq(plugin.settings.mode, "manual")
    ok(plugin.learning)
    ok(infoTexts()[#infoTexts()]:find("First, Spotlight learns your pace"))
    eq(Fake.pendingTasks(), 0)
end)

test("the Mode menu shows how far learning has got", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    read(plugin, 13) -- the first sentence after opening does not count
    local items = plugin:getModeMenu()
    eq(items[2].text_func(), "Auto (learning your pace: 12 of 40 sentences)")
end)

test("after 40 valid sentences and 3 minutes: Auto is ready", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    read(plugin, 39)
    eq(Fake.lastConfirm(), nil)
    read(plugin, 5)
    local popup = Fake.lastConfirm()
    ok(popup, "the popup is shown")
    local n = tonumber(popup.text:match("about (%d+) words a minute"))
    ok(n and math.abs(n - 214) <= 12, "measured pace " .. tostring(n))
    ok(popup.text:find("^Auto is ready%. You read about %d+ words a minute%. The light will move on its own%. Hold anywhere to pause; let go to continue%.$"))
    eq(popup.ok_text, "Start Auto")
    eq(popup.cancel_text, "Keep tapping")
    -- The fixed pause was learned too (0.5 s, within the 0.2 to 1.5 s range).
    ok(math.abs(plugin.model.pause_ms - 500) < 300, "pause " .. plugin.model.pause_ms)
end)

test("Start Auto: the light runs at the learned pace", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    read(plugin, 60)
    Fake.lastConfirm().ok_callback()
    ok(plugin:isAuto() and plugin.pacer:isRunning())
    local pace, source = plugin:currentPace()
    eq(source, "yours")
    eq(plugin.view.footer:text(), "Auto · " .. pace.wpm .. " wpm")
    -- Next sentence: the learned pause plus its words at the learned speed.
    Fake.advance(plugin.pacer:untilDue(Fake.clock_ms))
    local s = plugin:currentSentence()
    local expected = pace.pause_ms + s.words * 60000 / pace.wpm
    ok(math.abs(plugin.pacer:untilDue(Fake.clock_ms) - expected) < 2)
end)

test("Keep tapping: stay in Manual; choosing Auto later starts it at once", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    read(plugin, 60)
    Fake.shown = {}
    -- "Keep tapping" just closes the popup.
    eq(plugin.settings.mode, "manual")
    ok(plugin.learned and not plugin.learning)
    plugin:setMode("auto")
    ok(plugin:isAuto())
    eq(Fake.lastConfirm(), nil)
end)

test("enough Manual reading before choosing Auto: ready straight away", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    read(plugin, 50) -- just reading in Manual mode
    eq(Fake.lastConfirm(), nil) -- no popup while nobody asked for Auto
    plugin:setMode("auto")
    ok(Fake.lastConfirm(), "Auto is ready at once")
end)

test("the pace keeps up with Manual reading over time", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    read(plugin, 50)
    Fake.shown = {} -- "Keep tapping"
    local before = plugin:paceWpm()
    -- Weeks later, reading faster: 200 ms a word (300 wpm).
    read(plugin, 90, 500, 200)
    ok(plugin:paceWpm() > before + 40, before .. " -> " .. plugin:paceWpm())
end)

test("each book keeps its own pace once adjusted; new books start from yours", function()
    Fake.resetSettings()
    Fake.seedLearned(200, 400)
    local book_a = newPlugin()
    book_a:setMode("auto")
    book_a:onSpotlightFaster()
    book_a:onSpotlightFaster()
    eq(book_a:paceWpm(), 210)
    eq(select(2, book_a:currentPace()), "book")
    book_a:onSaveSettings()
    local saved = book_a.ui.doc_settings.data.spotlight_pace
    eq(saved.wpm, 210)
    -- Another book: your pace.
    local book_b = newPlugin()
    eq(book_b:paceWpm(), 200)
    eq(select(2, book_b:currentPace()), "yours")
    -- Book A again: its own.
    local again = newPlugin({ doc_settings = { spotlight_pace = saved } })
    eq(again:paceWpm(), 210)
end)

-- Auto-adjust in a running Auto session ----------------------------------------

local function autoSession()
    Fake.resetSettings()
    Fake.seedLearned(200, 400)
    local plugin = newPlugin()
    plugin:setMode("auto")
    return plugin
end

local function due(plugin) return plugin.pacer:untilDue(Fake.clock_ms) end

test("auto-adjust: 3 holds in 15 sentences slow the light by 5 %, quietly", function()
    local plugin = autoSession()
    local popups = #Fake.shown
    for i = 1, 15 do
        if i == 3 or i == 7 or i == 11 then
            plugin:onGesture({ ges = "touch", pos = RIGHT })
            plugin.registered.zones.spotlight_hold.handler({ ges = "hold", pos = RIGHT })
            Fake.advance(2000)
            plugin:onGesture({ ges = "hold_release", pos = RIGHT })
        end
        Fake.advance(due(plugin))
    end
    eq(plugin:paceWpm(), 190)
    eq(plugin.view.footer:text(), "Auto · 190 wpm") -- shown only in the indicator
    eq(#Fake.shown, popups)                        -- no popup
    eq(plugin.ui.doc_settings.data.spotlight_pace.wpm, 190) -- kept for this book
end)

test("auto-adjust: a skip-ahead and no stops speed it up by 5 %", function()
    local plugin = autoSession()
    tap(plugin) -- skip
    for _i = 1, 14 do Fake.advance(due(plugin)) end
    eq(plugin:paceWpm(), 210)
end)

test("auto-adjust: two quiet windows in a row speed it up by 2 %", function()
    local plugin = autoSession()
    for _i = 1, 30 do Fake.advance(due(plugin)) end
    eq(plugin:paceWpm(), 204)
end)

test("auto-adjust off: the speed stays", function()
    local plugin = autoSession()
    plugin.settings.auto_adjust = false
    tap(plugin)
    for _i = 1, 30 do Fake.advance(due(plugin)) end
    eq(plugin:paceWpm(), 200)
end)

test("turning Auto off shows how the speed went this session", function()
    local plugin = autoSession()
    for _i = 1, 30 do Fake.advance(due(plugin)) end
    plugin:setMode("manual")
    local msg = Fake.shown[#Fake.shown]
    eq(msg.text, "Started at 200, ended at 204 words a minute.")
    eq(msg.timeout, 3)
end)

test("closing the book shows it too", function()
    local plugin = autoSession()
    plugin:onCloseDocument()
    eq(Fake.shown[#Fake.shown].text, "Started at 200, ended at 200 words a minute.")
end)

test("no session summary when Auto was not used", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    Fake.shown = {}
    plugin:onCloseDocument()
    eq(#Fake.shown, 0)
end)

test("Learn my pace again: forgets timings, pace and this book's speed", function()
    local plugin = autoSession()
    plugin:onSpotlightFaster()
    local items = {}
    plugin:addToMainMenu(items)
    local relearn
    for _i, item in ipairs(items.spotlight.sub_item_table) do
        if item.text == "Learn my pace again" then relearn = item end
    end
    relearn.callback()
    local confirm = Fake.lastConfirm()
    ok(confirm and confirm.ok_text == "Learn again")
    confirm.ok_callback()
    eq(plugin.settings.mode, "manual")
    ok(not plugin.learned and plugin.learning)
    eq(#plugin.samples, 0)
    eq(plugin.model, nil)
    eq(plugin.ui.doc_settings.data.spotlight_pace, nil)
    eq(select(2, plugin:currentPace()), "default")
end)

test("the learned pace and timings are saved in Spotlight's settings file", function()
    Fake.resetSettings()
    local plugin = newPlugin()
    plugin:setMode("auto")
    read(plugin, 60)
    plugin:onSaveSettings()
    local data = Fake.store_files["/fake/settings/spotlight.lua"].data
    ok(data.learned == true and data.learning == false)
    ok(data.model and data.model.wpm > 150)
    ok(#data.manual_samples >= 40)
end)

test("upgrading from 0.3 with Auto on: learning starts (Auto is not used unlearned)", function()
    Fake.resetSettings()
    G_reader_settings:saveSetting("spotlight", { enabled = true, mode = "auto", wpm = 230 })
    local plugin = Fake.newPlugin(longBook())
    Fake.advance(0) -- run the next tick
    eq(plugin.settings.mode, "manual")
    ok(plugin.learning)
    ok(infoTexts()[#infoTexts()]:find("First, Spotlight learns your pace"))
end)

test("upgrading with enough Manual timings already: Auto is ready at once", function()
    Fake.resetSettings()
    local reader = Fake.newPlugin(longBook())
    reader:setEnabled(true)
    read(reader, 50)
    reader:onSaveSettings()
    G_reader_settings:saveSetting("spotlight", { enabled = true, mode = "auto", wpm = 230 })
    Fake.shown = {}
    local plugin = Fake.newPlugin(longBook())
    Fake.advance(0)
    ok(Fake.lastConfirm() and Fake.lastConfirm().text:find("Auto is ready"))
end)
