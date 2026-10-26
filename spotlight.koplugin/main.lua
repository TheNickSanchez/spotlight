--[[--
Spotlight: a sentence spotlight for reflowable (CREngine) books.

The current sentence gets a light gray band and a black bar in the left
margin (the trail marker). This file is the KOReader side: reading sentences
from the page, drawing, input, menus and events. Sentence rules live in
sentences.lua, timing and pacing in pace.lua.

Milestones so far:
  M1  menu toggle, sentences for the current page plus one page ahead, the
      band and bar.
  M2  Manual mode: taps and page keys move the light, sentences cross page
      breaks, the sentence is remembered per book, every sentence is timed.
  M3  Auto mode (the pacer): the light moves on its own; hold to pause, let
      go to continue; tap to skip or go back; speed panel; indicator.
  M4  learning your pace before Auto starts, the "Auto is ready" popup, the
      pace model, a pace per book, auto-adjust.
  M5  session stats (stats.lua), saved as JSON; the stats screen; export.

@module koplugin.spotlight
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
-- `_` is KOReader's translation function: never use `_` as a loop variable
-- in this file (that is why loops here use `_i`).
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- Load our own modules by file path, so a same-named file in another plugin
-- can never be picked up instead.
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local function loadModule(name)
    return dofile(plugin_dir .. "/" .. name .. ".lua")
end
local Sentences = loadModule("sentences")
local Pace = loadModule("pace")
local Stats = loadModule("stats")
local cfg = Pace.config

local DEFAULTS = {
    enabled = false,
    style = "band_bar",  -- "band_bar", "bar" or "underline"
    darkness = 0.2,      -- band: share of black blended over the page (KOReader's own highlight uses 0.2)
    bar_width = 5,       -- trail marker width, in screen pixels
    night_look = "bright", -- band in night mode: "bright" (sentence in day colours) or "glow" (dim band)
    mode = "manual",     -- "manual" (you move the light) or "auto" (the pacer moves it)
    wpm = cfg.default_wpm, -- Auto speed before your pace is learned, words per minute
    auto_adjust = true,  -- let Auto nudge the speed from your holds, backs and skips
}

local STYLES = {
    { "band_bar", _("Band and bar") },
    { "bar", _("Bar only") },
    { "underline", _("Underline only") },
}
local DARKNESS = {
    { 0.12, _("Light") },
    { 0.2, _("Medium") },
    { 0.3, _("Dark") },
}
local BAR_WIDTHS = { 4, 5, 6 }
local MODES = {
    { "manual", _("Manual") },
    { "auto", _("Auto") },
}
local NIGHT_LOOKS = {
    { "bright", _("Bright sentence (day colours)") },
    { "glow", _("Soft glow (dim band)") },
}

-- KOReader's own tap areas (top menu, bottom settings bar, and the corners
-- and footer inside them). Taps there are left to KOReader.
local KOREADER_TAP_ZONES = { "DTAP_ZONE_MENU", "DTAP_ZONE_MENU_EXT", "DTAP_ZONE_CONFIG", "DTAP_ZONE_CONFIG_EXT" }

-- ReaderRolling's page-turn key entries. While Spotlight is active they are
-- set inactive and Spotlight handles the same keys (see updateKeyCapture).
local PAGE_KEYS = { GotoNextView = 1, GotoPrevView = -1 }

-- Gestures that are part of a finger still on the screen. Any other gesture
-- (tap, hold_release, swipe, pan_release, two-finger gestures...) means the
-- contact is over.
local STILL_TOUCHING = {
    touch = true, hold = true, hold_pan = true, pan = true,
    two_finger_hold = true, two_finger_pan = true, two_finger_hold_pan = true,
}

--- Offset of a text xpointer ("/body/p[3]/text().42" -> 42), 0 if none.
local function xpOffset(xp)
    return tonumber(xp:match("%.(%d+)$")) or 0
end

local VERSION = "0.5.0 (M5)"

local MENU_SEPARATOR = "----------------------------"

local function labelFor(list, value)
    for _i, item in ipairs(list) do
        if item[1] == value then return item[2] end
    end
    return tostring(value)
end

--[[
Put Spotlight at the top of the first menu tab (navigation). A plugin entry
otherwise goes to the end of that tab, which already has more than one
page's worth of items (the touch menu shows 10 per page), so it lands on the
second page where it is easy to miss. KOReader's own helper for plugin menus
(frontend/ui/plugin/insert_menu.lua) edits this same order table; we only
add our id, once per KOReader run. If the table is not there, the entry
falls back to the end of the tab (sorting_hint below).
]]
local function placeInMenu()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" or type(order.navi) ~= "table" then return false end
    for _i, id in ipairs(order.navi) do
        if id == "spotlight" then return true end
    end
    table.insert(order.navi, 1, "spotlight")
    table.insert(order.navi, 2, MENU_SEPARATOR)
    return true
end

local Spotlight = WidgetContainer:extend{
    name = "spotlight",
    is_doc_only = true,
}

function Spotlight:init()
    -- The menu entry is registered for every book, so it can be found, and
    -- say why Spotlight is unavailable when it is.
    placeInMenu()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Only reflowable books rendered by CREngine (EPUB, FB2, HTML, TXT...).
    if not self.ui.rolling then
        logger.info("Spotlight", VERSION, ": not a reflowable book, staying off")
        return
    end
    local ok, err = pcall(self.setup, self)
    if ok then
        logger.info("Spotlight", VERSION, ": ready, turned", self.settings.enabled and "on" or "off")
    else
        self.pages = nil -- isSupported() is false: draw nothing, handle nothing
        self.startup_error = tostring(err)
        logger.err("Spotlight", VERSION, ": could not start:", err)
    end
end

function Spotlight:setup()
    self.settings = self:loadSettings()
    self.pages = {}         -- page number -> { page, sentences }
    self.current = nil      -- { page, index } of the lit sentence
    self.lit_region = nil   -- screen area covered by the highlight as last painted
    self.geom_version = 0   -- bumped when the look changes, to redo cached geometry
    self.turn_target = nil  -- set while Spotlight turns the page itself
    self.pending_key = nil  -- sentence to light once the page is rebuilt
    self.timing = nil       -- the lit sentence's timing in progress
    self.seen = {}          -- keys of sentences lit in this session (to spot rereads)
    -- Auto mode (M3)
    self.pacer = Pace.newPacer()
    self.pacer_task = function() self:onPacerTick() end -- the one scheduled timer
    self.pause_reasons = {} -- why Auto is paused: touch, sleep, waiting (for a first tap)
    self.last_advance = nil -- the last automatic move: { at, page, index }
    self.session = { holds = 0, backs = 0, skips = 0, adjustments = 0 } -- counts for stats (M5)
    self.book_pace = nil    -- this book's own pace { wpm, pause_ms }, once adjusted
    self.adjuster = nil     -- auto-adjust windows (pace.lua)
    self.auto_session = nil -- { start_wpm } while Auto has been used since the book opened
    self.stats_session = nil -- the reading session for the stats (stats.lua)
    self:openStore()
    self.view:registerViewModule("spotlight", self)
    self:registerTouchZones()
end

function Spotlight:loadSettings()
    local s = G_reader_settings:readSetting("spotlight") or {}
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

function Spotlight:saveSettings()
    G_reader_settings:saveSetting("spotlight", self.settings)
end

--- Spotlight's own file in KOReader's settings folder: timings across books.
--[[
Spotlight's own file in KOReader's settings folder (shared by all books):
  manual_samples  valid timings from Manual reading (the newest 400)
  model           your pace fitted from them { wpm, pause_ms, n, fallback }
  learned         true once "Auto is ready" has been reached
  learning        true while learning was asked for (Auto chosen, not ready)
]]
function Spotlight:openStore()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/spotlight.lua")
    self.samples = self.store:readSetting("manual_samples", {})
    self.model = self.store:readSetting("model")
    self.learned = self.store:readSetting("learned") == true
    self.learning = self.store:readSetting("learning") == true
    self.store_dirty = false
end

function Spotlight:flushStore()
    if self.store and self.store_dirty then
        self.store:saveSetting("manual_samples", self.samples)
        self.store:saveSetting("model", self.model)
        self.store:saveSetting("learned", self.learned)
        self.store:saveSetting("learning", self.learning)
        self.store:flush()
        self.store_dirty = false
    end
end

--[[
The pace Auto uses in this book, and where it comes from:
  "book"     this book's own pace (it was adjusted here)
  "yours"    your learned pace (books start from it)
  "default"  nothing learned yet
]]
function Spotlight:currentPace()
    if self.book_pace then return self.book_pace, "book" end
    if self.learned and self.model then
        return { wpm = Pace.clampWpm(self.model.wpm), pause_ms = self.model.pause_ms }, "yours"
    end
    return Pace.defaultPace(self.settings.wpm), "default"
end

function Spotlight:paceWpm()
    return (self:currentPace()).wpm
end

function Spotlight:isSupported()
    return self.pages ~= nil
end

--- Spotlight is drawing and listening: turned on, and the book is in page mode.
function Spotlight:isActive()
    return self.pages ~= nil and self.settings.enabled and self.view.view_mode == "page"
end

--- Auto mode is on (whether or not it is paused right now).
function Spotlight:isAuto()
    return self:isActive() and self.settings.mode == "auto"
end

function Spotlight:currentPage()
    return self.ui.document:getCurrentPage()
end

--- Page numbers per screen: 2 in two-page mode when each half has its own number.
function Spotlight:pageStep()
    local doc = self.ui.document
    return doc.getVisiblePageNumberCount and doc:getVisiblePageNumberCount() or 1
end

---------------------------------------------------------------------------
-- Reading sentences from the book
---------------------------------------------------------------------------

--[[
Sentences overlapping one screen (page).

crengine has no sentence or paragraph API, so we walk word by word:
getNextVisibleWordEnd / getPrevVisibleWordEnd step from word end to word end,
and getTextFromXPointers gives the text between two word ends (one "chunk":
the gap before a word plus the word). crengine puts "\n" in that text at every
block boundary, which is how paragraphs, headings and list items are found.

We walk back from the page's first word to the start of its paragraph, so a
sentence that began on the previous page is found whole, and past the page
end until the last sentence on the page is closed.

Reading text marks crengine's page image as stale (its next paint re-renders
the page), so this runs only when a page is first needed, right before that
page is painted anyway, and never while stepping between sentences.
]]
function Spotlight:buildPage(page)
    local doc = self.ui.document
    local started = time.now()
    local entry = { page = page, sentences = {} }

    local next_page = page + self:pageStep()
    local p0 = doc:getPageXPointer(page)
    local p1 = next_page <= doc:getPageCount() and doc:getPageXPointer(next_page) or nil
    if p1 == "" then p1 = nil end
    local e1 = p0 and p0 ~= "" and doc:getNextVisibleWordEnd(p0)
    if not e1 or (p1 and doc:compareXPointers(e1, p1) ~= 1) then
        return entry -- no text on this page (an image, a blank page)
    end

    -- where: 0 = previous page, 1 = this page, 2 = next page
    local back = {}
    local x = e1
    for _i = 1, cfg.max_words_back do
        local pe = doc:getPrevVisibleWordEnd(x)
        local chunk
        if pe then
            chunk = doc:getTextFromXPointers(pe, x) or ""
        else
            -- first word of the book
            local s = doc:getPrevVisibleWordStart(x)
            chunk = "\n" .. (s and doc:getTextFromXPointers(s, x) or "")
        end
        back[#back + 1] = { e = x, chunk = chunk, where = 0 }
        if not pe or chunk:find("\n", 1, true) then break end
        x = pe
    end
    local tokens = {}
    for i = #back, 1, -1 do tokens[#tokens + 1] = back[i] end
    tokens[#tokens].where = 1 -- e1 is on this page

    -- Past the page end, stop at the end of the paragraph, or once two
    -- possible sentence ends have gone by (the last sentence on the page is
    -- then closed, and the word after it is known for the lower-case rule).
    local tail
    local open_end = false
    local past, ends_past = 0, 0
    x = e1
    while true do
        local e = doc:getNextVisibleWordEnd(x)
        if not e then
            -- End of the book: keep the punctuation after the last word.
            local last = x
            for _i = 1, 8 do
                local c = doc:getNextVisibleChar(last)
                if not c then break end
                last = c
            end
            if last ~= x then tail = doc:getTextFromXPointers(x, last) end
            break
        end
        local chunk = doc:getTextFromXPointers(x, e) or ""
        local where = 1
        if p1 and (past > 0 or doc:compareXPointers(e, p1) ~= 1) then
            where = 2
            past = past + 1
            local nl = chunk:find("\n", 1, true)
            if nl then
                tail = chunk:sub(1, nl) -- closing punctuation before the block ends
                break
            end
            if past > cfg.max_words_past_page then
                open_end = true
                break
            end
            if chunk:find("[%.!%?]") or chunk:find("…", 1, true) then
                ends_past = ends_past + 1
            end
        end
        tokens[#tokens + 1] = { e = e, chunk = chunk, where = where }
        if ends_past >= 2 then
            open_end = true
            break
        end
        x = e
    end

    local chunks = {}
    for i, t in ipairs(tokens) do chunks[i] = t.chunk end
    for _i, s in ipairs(Sentences.split(chunks, tail, { open_end = open_end })) do
        local a, b = tokens[s.first], tokens[s.last]
        if b.where >= 1 and a.where <= 1 then
            -- Share of the sentence on this page (Auto mode gives each part
            -- of a sentence split by a page break its share of the time).
            local here = 0
            for i = s.first, s.last do
                if tokens[i].where == 1 then here = here + 1 end
            end
            entry.sentences[#entry.sentences + 1] = {
                share = here / (s.last - s.first + 1),
                key = a.e,          -- the same sentence has the same key on both pages
                first_e = a.e,      -- end of its first word
                last_e = b.e,       -- end of its last word
                lead = s.lead,
                trail = s.trail,
                words = s.words,
                text = s.text,
                starts_before = a.where == 0,
                ends_after = b.where == 2,
            }
        end
    end

    -- The page's text range, to find where its lines start on screen (textLeft).
    entry.p0 = p0
    entry.p_end = p1 or (tokens[#tokens] and tokens[#tokens].e)

    logger.info(string.format("Spotlight: page %d, %d sentences from %d words in %d ms",
        page, #entry.sentences, #tokens, time.to_ms(time.since(started))))
    return entry
end

function Spotlight:getPage(page)
    if page < 1 or page > self.ui.document:getPageCount() then return nil end
    if not self.pages[page] then
        self.pages[page] = self:buildPage(page)
    end
    return self.pages[page]
end

--- Keep only the pages around the current one.
function Spotlight:prunePages(page)
    local step = self:pageStep()
    for p in pairs(self.pages) do
        if p < page - step or p > page + step then self.pages[p] = nil end
    end
end

--- Forget everything computed from the current layout. The lit sentence (or
-- `key`) is lit again once its page is rebuilt.
function Spotlight:invalidate(key)
    if not self.pages then return end
    local s = self:currentSentence()
    self.pending_key = key or (s and s.key) or self.pending_key
    self.pages = {}
    self.current = nil
    self.timing = nil
end

function Spotlight:currentSentence()
    local c = self.current
    local entry = c and self.pages[c.page]
    return entry and entry.sentences[c.index]
end

local function indexOfKey(entry, key)
    for i, s in ipairs(entry.sentences) do
        if s.key == key then return i end
    end
end

--[[
Pick the sentence to light on a page that was just shown.

target (optional):
  { key, mode = "same" }    the sentence with this key (it continues here,
                            or it is being restored)
  { key, mode = "after" }   the sentence after it (first one if not here)
  { key, mode = "before" }  the sentence before it (last one if not here)
Without a target: the first sentence on the page, which may be the end of a
sentence that began on the previous page.
]]
function Spotlight:selectOnPage(page, target)
    if not target and self.pending_key then
        target = { key = self.pending_key, mode = "same" }
    end
    self.pending_key = nil
    local entry = self:getPage(page)
    self:getPage(page + self:pageStep()) -- one page ahead
    self:prunePages(page)
    if not entry or #entry.sentences == 0 then
        self.current = nil
        self.timing = nil
        return
    end

    local n = #entry.sentences
    local found = target and indexOfKey(entry, target.key)
    local idx = 1
    if target and target.mode == "same" then
        idx = found or 1
    elseif target and target.mode == "after" then
        idx = found and math.min(found + 1, n) or 1
    elseif target and target.mode == "before" then
        idx = found and math.max(found - 1, 1) or n
    end
    self.current = { page = page, index = idx }

    local s = entry.sentences[idx]
    self:statsActivity()
    if self:isAuto() then
        self:startSentenceClock(s, (target and target.continues) and "continue" or "turn")
    elseif target and target.continues and self.timing and self.timing.key == s.key then
        -- The same sentence, carried over to the new page: keep its clock
        -- running, but the page turn makes the timing unusable for learning.
        self.timing.after_turn = true
    else
        self:startTiming(s, true)
    end
end

---------------------------------------------------------------------------
-- Moving the light
---------------------------------------------------------------------------

--- Light a sentence on the page being shown, refreshing only the old and new areas.
function Spotlight:light(page, index)
    local old = self.lit_region
    self.current = { page = page, index = index }
    local s = self:currentSentence()
    self:statsActivity()
    if self:isAuto() then
        self:startSentenceClock(s, "step")
    else
        self:startTiming(s, false)
    end
    self:refresh(old, s and self:geometry(s).region)
end

--- Turn the page ourselves. KOReader turns it as usual (counting it for its
-- full refresh), and onPageUpdate picks the sentence from `target`.
function Spotlight:turnPage(dir, target)
    self.turn_target = target or false
    self.ui:handleEvent(Event:new("GotoViewRel", dir))
    self.turn_target = nil
end

--- Next sentence. cause: "tap" (Manual), "auto" (the pacer) or "skip"
-- (a tap in Auto mode).
function Spotlight:stepForward(cause)
    local s = self:currentSentence()
    if not s then
        self:turnPage(1) -- nothing to light here (an image page)
        return
    end
    local c = self.current
    if s.ends_after and cause ~= "skip" then
        -- Show the rest of this sentence on the next page.
        self:turnPage(1, { key = s.key, mode = "same", continues = true })
        return
    end
    self:statsSentenceRead(s)
    if s.ends_after then
        -- Skipping a sentence split by a page break: past its rest too.
        self:turnPage(1, { key = s.key, mode = "after" })
        return
    end
    if not self:isAuto() then self:finishTiming() end
    if c.index < #self.pages[c.page].sentences then
        self:light(c.page, c.index + 1)
    else
        self:turnPage(1, { key = s.key, mode = "after" })
    end
end

function Spotlight:stepBackward()
    if self:isAuto() then self.session.backs = self.session.backs + 1 end
    self:statsCount("backs")
    local s = self:currentSentence()
    self.timing = nil -- going back: no timing for the sentence we leave
    if not s then
        self:turnPage(-1)
        return
    end
    local c = self.current
    if s.starts_before then
        -- Show the beginning of this sentence on the previous page.
        self:turnPage(-1, { key = s.key, mode = "same" })
    elseif c.index > 1 then
        self:light(c.page, c.index - 1)
    else
        self:turnPage(-1, { key = s.key, mode = "before" })
    end
end

---------------------------------------------------------------------------
-- Auto mode: the pacer
---------------------------------------------------------------------------

local function nowMs()
    return time.to_ms(time.now())
end

function Spotlight:isPaused()
    return next(self.pause_reasons) ~= nil
end

--- How long a sentence stays lit. how: "step" (the next sentence on the
-- page), "turn" (the first one after a page turn), "continue" (the rest of a
-- sentence split by a page break) or "start" (Auto just started).
function Spotlight:sentenceMsFor(s, how)
    local words = s.words * (s.share or 1)
    local ms = Pace.sentenceMs(words, self:currentPace(), how ~= "continue")
    if how ~= "step" then
        ms = ms + cfg.page_turn_grace_ms
    end
    return ms
end

--- A sentence was lit in Auto mode: start its countdown.
function Spotlight:startSentenceClock(s, how)
    if not s then
        self.pacer:stop()
        UIManager:unschedule(self.pacer_task)
        return
    end
    local now = nowMs()
    self.pacer:start(now, self:sentenceMsFor(s, how))
    if self:isPaused() then
        self.pacer:pause(now)
    end
    self:scheduleTick()
end

--- (Re)schedule the one timer for when the lit sentence is due.
function Spotlight:scheduleTick()
    UIManager:unschedule(self.pacer_task)
    local ms = self.pacer:untilDue(nowMs())
    if ms then
        UIManager:scheduleIn(ms / 1000, self.pacer_task)
    end
end

function Spotlight:readerOnTop()
    return UIManager:getTopmostVisibleWidget() == self.ui
end

function Spotlight:onPacerTick()
    if not self:isAuto() or self:isPaused() then return end
    local now = nowMs()
    local left = self.pacer:untilDue(now)
    if not left then return end
    if left > 5 then
        self:scheduleTick() -- woke up early
        return
    end
    if not self:readerOnTop() then
        -- A menu or dialog covers the page: wait for it to close.
        self.blocked = true
        UIManager:scheduleIn(cfg.blocked_poll_s, self.pacer_task)
        return
    end
    if self.blocked then
        -- It just closed: give a moment to find the sentence again.
        self.blocked = false
        self.pacer:start(now, cfg.dialog_resume_grace_ms)
        self:scheduleTick()
        return
    end
    self:keepKindleAwake(now)
    local before = self:currentSentence()
    self.last_advance = { at = now, page = self.current and self.current.page, index = self.current and self.current.index }
    self:stepForward("auto")
    if self:currentSentence() == before then
        -- Nothing after it: the end of the book. Wait for a tap.
        self:pauseAuto("end")
    elseif not (before and before.ends_after) then
        self:noteAuto("sentence") -- a whole sentence went by (not just half of a split one)
    end
end

function Spotlight:pauseAuto(reason)
    self.pause_reasons[reason] = true
    self.pacer:pause(nowMs())
    UIManager:unschedule(self.pacer_task)
    self:setKeepAwake(false)
end

--- Clear one pause reason; when none is left, continue with the time that
-- was left plus `grace`.
function Spotlight:resumeAuto(reason, grace)
    if not self.pause_reasons[reason] then return end
    self.pause_reasons[reason] = nil
    if self:isPaused() or not self:isAuto() then return end
    if self.pacer:isPaused() then
        self.pacer:resume(nowMs(), grace)
    elseif not self.pacer:isRunning() then
        self:startSentenceClock(self:currentSentence(), "start")
        return
    end
    self:setKeepAwake(true)
    self:scheduleTick()
end

--- Auto starts (or the book opens in Auto mode).
-- waiting: stay paused until the first tap (used when a book opens).
function Spotlight:startAuto(waiting)
    if not self:isAuto() then return end
    self.pause_reasons = {}
    if waiting then self.pause_reasons.waiting = true end
    self.blocked = false
    self.adjuster = Pace.newAdjuster()
    if not self.auto_session then
        self.auto_session = { start_wpm = self:paceWpm() }
    end
    self:startSentenceClock(self:currentSentence(), "start")
    if not self:isPaused() then self:setKeepAwake(true) end
    self:updateIndicator()
end

--- Auto stops: Manual mode, Spotlight off, scroll mode, closing the book.
function Spotlight:stopAuto()
    if not self.pacer then return end
    self.pacer:stop()
    UIManager:unschedule(self.pacer_task)
    self.pause_reasons = {}
    self.blocked = false
    self:setKeepAwake(false)
    self:updateIndicator()
end

--[[
While Auto runs there is no input, so KOReader's auto-suspend and the
Kindle's own 10-minute sleep timer would put the device to sleep mid-chapter.
Like KOReader's Auto-turn plugin, set PluginShare.pause_auto_suspend while
running (restoring whatever it was before, so the Keep-alive plugin is left
alone), and on a Kindle tell the power manager the reader is in use every
few minutes, the way the AutoSuspend plugin does.
]]
function Spotlight:setKeepAwake(on)
    if on == (self.keeping_awake or false) then return end
    self.keeping_awake = on
    if on then
        self.prev_pause_auto_suspend = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
        self.last_wake = nil
        self:keepKindleAwake(nowMs())
    else
        PluginShare.pause_auto_suspend = self.prev_pause_auto_suspend
    end
end

function Spotlight:keepKindleAwake(now)
    if not self.keeping_awake or not Device:isKindle() then return end
    if self.last_wake and now - self.last_wake < cfg.keep_awake_every_s * 1000 then return end
    local powerd = Device:getPowerDevice()
    if powerd and powerd.resetT1Timeout then
        powerd:resetT1Timeout()
    end
    self.last_wake = now
end

--- Change the speed for this book (it keeps its own pace from now on). The
-- time left on the lit sentence stretches with it.
function Spotlight:setWpm(wpm)
    wpm = Pace.clampWpm(wpm)
    local pace = self:currentPace()
    local old = pace.wpm
    if wpm == old then return end
    self.book_pace = { wpm = wpm, pause_ms = pace.pause_ms }
    self.ui.doc_settings:saveSetting("spotlight_pace", self.book_pace)
    if self.pacer and (self.pacer:isRunning() or self.pacer:isPaused()) then
        self.pacer:rescale(nowMs(), old, wpm)
        if self.pacer:isRunning() then self:scheduleTick() end
    end
    self:updateIndicator()
end

function Spotlight:setMode(mode)
    if not self:isSupported() or self.settings.mode == mode then return end
    if mode == "auto" and not self.learned then
        self:startLearning()
        return
    end
    -- Reading time so far belongs to the old mode, from now on to the new one.
    if self.stats_session then self:statsActivity() end
    self.settings.mode = mode
    self:saveSettings()
    if self.stats_session then self:statsActivity() end
    if mode == "auto" then
        self.timing = nil
        if self:isActive() and not self:currentSentence() then
            self:selectOnPage(self:currentPage())
        end
        self:startAuto(false)
    else
        self:stopAuto()
        self:showSessionPace()
        if self:isActive() then self:startTiming(self:currentSentence(), true) end
    end
end

---------------------------------------------------------------------------
-- Learning your pace (M4)
---------------------------------------------------------------------------

--[[
Auto was chosen before your pace is known. If Manual reading already gave
enough timings, Auto is ready at once; otherwise Spotlight stays in Manual
mode and learns while you tap, then offers Auto ("Auto is ready").
]]
function Spotlight:startLearning()
    local n, _ms, ready = Pace.learningProgress(self.samples)
    if ready and self.model then
        self:paceLearned()
        return
    end
    self.learning = true
    self.store_dirty = true
    if not self.settings.enabled then self:setEnabled(true) end
    UIManager:show(InfoMessage:new{
        text = T(_("First, Spotlight learns your pace.\n\nRead in Manual mode as usual, tapping to the next sentence. After about %1 more sentences (and at least 3 minutes of reading), Auto will be ready."),
            math.max(1, cfg.learn_min_sentences - n)),
    })
end

--- Enough timings: offer Auto.
function Spotlight:paceLearned()
    self.learned = true
    self.learning = false
    self.store_dirty = true
    self:flushStore()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Auto is ready. You read about %1 words a minute. The light will move on its own. Hold anywhere to pause; let go to continue."),
            math.floor(self.model.wpm + 0.5)),
        ok_text = _("Start Auto"),
        cancel_text = _("Keep tapping"),
        ok_callback = function() self:setMode("auto") end,
    })
end

--- A timing was kept: refine your pace, and offer Auto when learning is done.
function Spotlight:onSampleKept()
    self.model = Pace.fit(self.samples)
    self.store_dirty = true
    if self.learning and self.model and select(3, Pace.learningProgress(self.samples)) then
        self:paceLearned()
    end
end

--- "Learn my pace again": forget the timings and the learned pace.
function Spotlight:relearn()
    for i = #self.samples, 1, -1 do self.samples[i] = nil end
    self.model = nil
    self.learned = false
    self.book_pace = nil
    self.ui.doc_settings:delSetting("spotlight_pace")
    if self.settings.mode == "auto" then self:setMode("manual") end
    self:startLearning()
end

---------------------------------------------------------------------------
-- Auto-adjust (M4)
---------------------------------------------------------------------------

--- Tell auto-adjust what happened in Auto mode: "sentence", "skip", "hold", "back".
function Spotlight:noteAuto(kind)
    if not self:isAuto() or not self.adjuster then return end
    local factor, why = self.adjuster:note(kind)
    if factor and self.settings.auto_adjust then
        local old = self:paceWpm()
        local new = Pace.adjustedWpm(old, factor)
        if new ~= old then
            logger.info("Spotlight: auto-adjust", why, old, "->", new, "wpm")
            self.session.adjustments = self.session.adjustments + 1
            self:statsCount("auto_adjust_changes")
            self:setWpm(new) -- shown only through the indicator
        end
    end
end

--- Turning Auto off or closing the book: how the speed went this session.
function Spotlight:showSessionPace()
    local session = self.auto_session
    self.auto_session = nil
    if not session then return end
    UIManager:show(InfoMessage:new{
        text = T(_("Started at %1, ended at %2 words a minute."), session.start_wpm, self:paceWpm()),
        timeout = 3,
    })
end

--[[
Input in Auto mode. A plugin sees every gesture before ReaderUI's touch zones
run (ReaderUI passes events to its modules first), so this watches all of
them without taking any (it returns nothing):
  touch (finger down, sent at once)  pause
  any gesture that ends the contact   continue with what was left plus a
                                      short grace
Taps (skip, back) and holds are then handled by Spotlight's touch zones.
KOReader only reports a hold after 500 ms, which is why pausing happens on
finger down rather than on the hold.
]]
function Spotlight:onGesture(ev)
    if not self:isAuto() or not ev then return end
    if ev.ges == "touch" then
        self:onFingerDown()
    elseif not STILL_TOUCHING[ev.ges] then
        self:resumeAuto("touch", cfg.hold_resume_grace_ms)
    end
end

function Spotlight:onFingerDown()
    if self.pause_reasons.touch then return end
    -- If the light moved on just before the finger landed, the finger was
    -- meant for the sentence before: go back to it.
    local la = self.last_advance
    local now = nowMs()
    if la and la.page and now - la.at < cfg.touch_race_ms and self.current
            and self.current.page == la.page and la.index ~= self.current.index then
        self.last_advance = nil
        self:light(la.page, la.index)
    end
    self:pauseAuto("touch")
end

--- Holds in Auto mode: taken, so KOReader's dictionary and highlighting do
-- not open (the hold itself is the pause). In Manual mode they are KOReader's.
function Spotlight:onSpotlightHold()
    if not self:isAuto() then return end
    if self.ui.highlight and self.ui.highlight.hold_pos then return end
    return true
end

function Spotlight:onSpotlightHoldEvent(ges)
    if ges.ges == "hold" and self:isAuto() then
        self.session.holds = self.session.holds + 1
        self:statsCount("holds")
        self:noteAuto("hold")
    end
    return self:onSpotlightHold()
end

---------------------------------------------------------------------------
-- Session stats (M5)
---------------------------------------------------------------------------

function Spotlight:statsPath()
    return DataStorage:getSettingsDir() .. "/spotlight_stats.json"
end

function Spotlight:bookTitle()
    local props = self.ui.doc_props
    local title = props and (props.display_title or props.title)
    if not title or title == "" then
        title = ((self.ui.document and self.ui.document.file) or ""):match("([^/]+)$") or ""
    end
    return title
end

function Spotlight:statsSession()
    if not self.stats_session then
        self.stats_session = Stats.newSession{
            book_title = self:bookTitle(),
            started_at = os.time(),
            pace_wpm = self:paceWpm(),
            cfg = cfg,
        }
    end
    return self.stats_session
end

--- The light moved: the time since the last move counts as reading.
function Spotlight:statsActivity()
    if not self:isActive() then return end
    self:statsSession():activity(nowMs(), self.settings.mode, os.time())
end

function Spotlight:statsSentenceRead(s)
    if self:isActive() and s then self:statsSession():sentenceRead(s.words) end
end

function Spotlight:statsCount(field)
    if self:isActive() then self:statsSession():count(field) end
end

--- Read spotlight_stats.json: { format, version, fields, sessions = {...} }.
function Spotlight:loadStatsData()
    local util = require("util")
    local rapidjson = require("rapidjson")
    local path = self:statsPath()
    local text = util.readFromFile(path, "r")
    if text and text ~= "" then
        local ok, data = pcall(rapidjson.decode, text)
        if ok and type(data) == "table" and type(data.sessions) == "table" then
            return data
        end
        -- Unreadable: keep it aside instead of writing over it.
        local aside = path .. ".unreadable-" .. os.time()
        os.rename(path, aside)
        logger.warn("Spotlight: could not read", path, "- kept as", aside)
    end
    return { sessions = {} }
end

--- Write the stats as pretty JSON, with a description of every field.
function Spotlight:writeStatsData(data, path)
    local util = require("util")
    local rapidjson = require("rapidjson")
    local fields = {}
    for _i, f in ipairs(Stats.FIELDS) do fields[f[1]] = f[2] end
    local out = {
        format = "spotlight-sessions",
        version = 1,
        fields = fields,
        sessions = rapidjson.array and rapidjson.array(data.sessions) or data.sessions,
    }
    local ok, text = pcall(rapidjson.encode, out, { pretty = true, sort_keys = true })
    if not ok or not text then
        logger.err("Spotlight: could not encode the stats:", text)
        return false
    end
    return util.writeToFile(text, path, true) == true
end

--- Save the session so far. It is saved again (replaced) as it goes on;
-- `finish` ends it, so the next reading starts a new one.
function Spotlight:saveStatsSession(finish)
    local session = self.stats_session
    if not session then return end
    if finish then self.stats_session = nil end
    local record = session:record(self:paceWpm())
    if not record then return end
    local data = self:loadStatsData()
    Stats.upsert(data.sessions, record)
    self:writeStatsData(data, self:statsPath())
end

local function trend(cur, prev, decimals)
    if not cur or not prev then return "" end
    local diff = cur - prev
    local fmt = "%." .. decimals .. "f"
    if math.abs(diff) < 0.5 * 10 ^ -decimals then return "  " .. _("(same)") end
    -- U+2212 minus sign, so + and − line up
    return "  (" .. (diff > 0 and "+" or "−") .. string.format(fmt, math.abs(diff)) .. ")"
end

--- The rows of the stats screen (KeyValuePage).
function Spotlight:statsRows(report)
    local titles = {
        today = _("Today (trend vs yesterday)"),
        week = _("Last 7 days (trend vs the 7 days before)"),
        month = _("Last 30 days (trend vs the 30 days before)"),
    }
    local rows = {}
    for _i, p in ipairs(report) do
        local cur, prev = p.current, p.previous
        rows[#rows + 1] = { titles[p.key], "" }
        rows[#rows + 1] = { _("Minutes read"), string.format("%d", math.floor(cur.minutes + 0.5)) }
        rows[#rows + 1] = { _("Sentences"), tostring(cur.sentences) }
        rows[#rows + 1] = { _("Average pace"),
            cur.wpm and (T(_("%1 wpm"), math.floor(cur.wpm + 0.5)) .. trend(cur.wpm, prev.wpm, 0)) or "–" }
        rows[#rows + 1] = { _("Stops per 100 sentences"),
            cur.stops_per_100 and (string.format("%.1f", cur.stops_per_100) .. trend(cur.stops_per_100, prev.stops_per_100, 1)) or "–" }
        rows[#rows + 1] = "----"
    end
    rows[#rows + 1] = { _("Stops are holds and backs."), "" }
    return rows
end

function Spotlight:showStats()
    self:saveStatsSession(false) -- include the reading so far
    local data = self:loadStatsData()
    local KeyValuePage = require("ui/widget/keyvaluepage")
    UIManager:show(KeyValuePage:new{
        title = _("Spotlight stats"),
        single_page = true, -- all three periods at a glance
        kv_pairs = self:statsRows(Stats.report(data.sessions, os.date("%Y-%m-%d"))),
    })
end

--- Copy the stats to <home folder>/spotlight/spotlight_stats.json, where they
-- show up on the Kindle's USB storage (home is /mnt/us on a Kindle).
function Spotlight:exportStats()
    self:saveStatsSession(false)
    local data = self:loadStatsData()
    local util = require("util")
    local home = require("apps/filemanager/filemanagerutil").getHomeFolder()
    local dir = home .. "/spotlight"
    util.makePath(dir)
    local path = dir .. "/spotlight_stats.json"
    local ok = self:writeStatsData(data, path)
    UIManager:show(InfoMessage:new{
        text = ok and T(_("Exported %1 sessions to\n%2"), #data.sessions, path)
            or T(_("Could not write\n%1"), path),
    })
    return ok, path
end

---------------------------------------------------------------------------
-- Timing (learning the reading pace)
---------------------------------------------------------------------------

function Spotlight:startTiming(s, after_turn)
    if not s then
        self.timing = nil
        return
    end
    self.timing = {
        key = s.key,
        words = s.words,
        at = time.now(),
        reread = self.seen[s.key] == true,
        after_turn = after_turn or false,
    }
    self.seen[s.key] = true
end

--- Moving on from the lit sentence: keep its timing if it is a clean one.
function Spotlight:finishTiming()
    local t = self.timing
    self.timing = nil
    if not t then return end
    local sample = {
        words = t.words,
        ms = time.to_ms(time.since(t.at)),
        reread = t.reread,
        after_turn = t.after_turn,
        at = os.time(),
    }
    local kept = Pace.addSample(self.samples, sample)
    if kept then
        self.store_dirty = true
        self:onSampleKept()
    end
    logger.dbg("Spotlight: timing", sample.words, "words", sample.ms, "ms", kept and "kept" or "skipped")
    return sample, kept
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

--[[
One full-screen tap zone that comes before KOReader's page-turn taps and its
tap-on-highlight handler (via `overrides`). Its handler returns nothing when
Spotlight is off, and for taps in KOReader's menu and settings-bar areas, so
those reach KOReader unchanged. Links keep working: KOReader's link zone
already has priority over the zones we override, and it was registered first.
]]
function Spotlight:registerTouchZones()
    if not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({
        {
            id = "spotlight_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "tap_forward", "tap_backward", "readerhighlight_tap" },
            handler = function(ges) return self:onSpotlightTap(ges) end,
        },
        -- Auto mode: holds pause the light and must not open the dictionary
        -- or start a highlight. These return nothing in Manual mode.
        {
            id = "spotlight_hold",
            ges = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "readerhighlight_hold", "readerfooter_hold" },
            handler = function(ges) return self:onSpotlightHoldEvent(ges) end,
        },
        {
            id = "spotlight_hold_pan",
            ges = "hold_pan",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "readerhighlight_hold_pan" },
            handler = function(ges) return self:onSpotlightHoldEvent(ges) end,
        },
        {
            id = "spotlight_hold_release",
            ges = "hold_release",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "readerhighlight_hold_release" },
            handler = function(ges) return self:onSpotlightHoldEvent(ges) end,
        },
    })
end

function Spotlight:isKOReaderTapZone(pos)
    local w, h = Screen:getWidth(), Screen:getHeight()
    for _i, name in ipairs(KOREADER_TAP_ZONES) do
        local z = G_defaults:readSetting(name)
        if z and pos.x >= z.x * w and pos.x < (z.x + z.w) * w
                and pos.y >= z.y * h and pos.y < (z.y + z.h) * h then
            return true
        end
    end
    return false
end

function Spotlight:onSpotlightTap(ges)
    if not self:isActive() then return end
    -- A text selection is in progress: leave the tap to KOReader.
    if self.ui.highlight and self.ui.highlight.hold_pos then return end
    if self:isKOReaderTapZone(ges.pos) then return end
    self:onSentenceInput(ges.pos.x < Screen:getWidth() * cfg.back_zone_ratio and -1 or 1)
    return true
end

--- A tap or a page key: dir 1 forward, -1 back.
function Spotlight:onSentenceInput(dir)
    self.pause_reasons["end"] = nil
    if self:isAuto() and (self.pause_reasons.waiting or self.pause_reasons.sleep) then
        -- Auto is waiting for you (book just opened, or the Kindle woke up):
        -- this tap starts the light on the lit sentence.
        self.pause_reasons.waiting, self.pause_reasons.sleep = nil, nil
        self:startSentenceClock(self:currentSentence(), "start")
        if not self:isPaused() then self:setKeepAwake(true) end
        return
    end
    if dir > 0 then
        if self:isAuto() then
            self.session.skips = self.session.skips + 1
            self:statsCount("skip_aheads")
        end
        self:stepForward(self:isAuto() and "skip" or "tap")
        self:noteAuto("skip")
    else
        self:stepBackward()
        self:noteAuto("back")
    end
end

--[[
Page-turn keys. ReaderRolling handles them before any plugin sees them, so
while Spotlight is active we set its two key entries inactive (a flag
KOReader's key dispatcher checks, inputcontainer.lua) and match the same key
sequences here. Nothing else in ReaderRolling is touched, and the flag is
cleared as soon as Spotlight is off, in scroll mode, or the book closes.
]]
function Spotlight:updateKeyCapture()
    local ke = self.ui.rolling and self.ui.rolling.key_events
    if not ke then return end
    local on = self:isActive()
    for name in pairs(PAGE_KEYS) do
        if ke[name] then ke[name].is_inactive = on or nil end
    end
    self.keys_captured = on
end

function Spotlight:onKeyPress(key)
    if not self.keys_captured or not self:isActive() then return end
    local ke = self.ui.rolling.key_events
    for name, dir in pairs(PAGE_KEYS) do
        local seq = ke[name]
        if seq then
            for _i, oneseq in ipairs(seq) do
                if key:match(oneseq) then
                    self:onSentenceInput(dir)
                    return true
                end
            end
        end
    end
end

-- ReaderRolling rebuilds its key entries when a keyboard is connected
-- (it handles this event before us, so the new entries exist by now).
function Spotlight:onPhysicalKeyboardConnected()
    self:updateKeyCapture()
end

---------------------------------------------------------------------------
-- Geometry and drawing
---------------------------------------------------------------------------

--- xpointers of the sentence, including its opening and closing punctuation.
function Spotlight:sentenceRange(s)
    if s.pos0 then return s.pos0, s.pos1 end
    local doc = self.ui.document
    local pos0 = doc:getPrevVisibleWordStart(s.first_e) or s.first_e
    for _i = 1, s.lead do
        local p = doc:getPrevVisibleChar(pos0)
        if not p then break end
        pos0 = p
    end
    -- Stepping forward from the end of a text node first lands on offset 0 of
    -- the next one without passing a character, so only count real steps.
    local pos1 = s.last_e
    local passed, steps = 0, 0
    while passed < s.trail and steps < s.trail + 4 do
        local p = doc:getNextVisibleChar(pos1)
        if not p then break end
        steps = steps + 1
        if xpOffset(p) > 0 then passed = passed + 1 end
        pos1 = p
    end
    s.pos0, s.pos1 = pos0, pos1
    return pos0, pos1
end

--[[
Screen rectangles for a sentence on the page being shown: the band (one
rectangle per line), the underlines, and one bar per text column spanning
the sentence's lines. getScreenBoxesFromPositions only returns the lines that
are on the current page, which is exactly the visible part of a sentence
that runs over a page break.
]]
function Spotlight:geometry(s)
    if s.geom and s.geom.version == self.geom_version then return s.geom end
    local doc = self.ui.document
    local pos0, pos1 = self:sentenceRange(s)
    local g = { version = self.geom_version, bands = {}, underlines = {}, bars = {} }
    local boxes = {}
    for _i, b in ipairs(doc:getScreenBoxesFromPositions(pos0, pos1, true)) do
        if b.w > 0 and b.h > 0 then boxes[#boxes + 1] = b end
    end
    s.geom = g
    if #boxes == 0 then return g end

    local pad = Screen:scaleBySize(2)
    local thick = Screen:scaleBySize(2)
    local screen_w = Screen:getWidth()
    local two_columns = doc:getVisiblePageCount() > 1
    local columns = {}
    for _i, b in ipairs(boxes) do
        local band = Geom:new{ x = b.x - pad, y = b.y, w = b.w + 2 * pad, h = b.h }
        -- Lines of one sentence can overlap by a pixel or two. Inverting the
        -- overlap twice would cancel out, and darkening it twice shows a
        -- stripe, so each band starts where the one above it ends.
        local above = g.bands[#g.bands]
        if above and band.y < above.y + above.h and band.x < above.x + above.w and above.x < band.x + band.w then
            local bottom = band.y + band.h
            band.y = above.y + above.h
            band.h = math.max(0, bottom - band.y)
        end
        g.bands[#g.bands + 1] = band
        g.underlines[#g.underlines + 1] = Geom:new{ x = b.x, y = b.y + b.h - thick, w = b.w, h = thick }
        local col = (two_columns and b.x >= screen_w / 2) and 2 or 1
        local c = columns[col]
        if not c then
            columns[col] = { top = b.y, bottom = b.y + b.h }
        else
            c.top = math.min(c.top, b.y)
            c.bottom = math.max(c.bottom, b.y + b.h)
        end
    end

    if self.settings.style ~= "underline" then
        -- The bar sits a small gap left of where the page's lines start, at
        -- the same x for every sentence on the page, so it does not jump with
        -- paragraph indents. In two-page mode the right page gets its own.
        local w = self.settings.bar_width
        local lefts = self:textLeft(self.current and self.pages[self.current.page])
        for col, c in pairs(columns) do
            local origin = col == 2 and math.floor(screen_w / 2) or 0
            local left = lefts[col] or (origin + (doc:getPageMargins().left or 0))
            local room = left - origin - w
            local gap = math.min(Screen:scaleBySize(6), math.max(0, math.floor(room / 2)))
            local x = math.max(origin, left - gap - w)
            g.bars[#g.bars + 1] = Geom:new{ x = x, y = c.top, w = w, h = c.bottom - c.top }
        end
    end

    local all = {}
    for _i, r in ipairs(g.bands) do all[#all + 1] = r end
    for _i, r in ipairs(g.bars) do all[#all + 1] = r end
    g.region = Geom.boundingBox(all)
    return g
end

--- KOReader's night mode is on and the night look is "Bright sentence".
function Spotlight:isNightBright()
    return Screen.night_mode == true and self.settings.night_look == "bright"
end

--[[
Where the lines of the shown page start on screen, per text column:
{ [1] = x, [2] = x in two-page mode }. KOReader's page margin is not enough:
the book's own stylesheet can add its own margin on top of it, so this
looks at the lines themselves. Their leftmost start is the column edge
(indented first lines start further right). Computed once per page.
]]
function Spotlight:textLeft(entry)
    if not entry or not entry.p0 or not entry.p_end then return {} end
    if entry.text_left then return entry.text_left end
    local lefts = {}
    local half = Screen:getWidth() / 2
    local two_columns = self.ui.document:getVisiblePageCount() > 1
    for _i, b in ipairs(self.ui.document:getScreenBoxesFromPositions(entry.p0, entry.p_end, true)) do
        if b.w > 0 and b.h > 0 then
            local col = (two_columns and b.x >= half) and 2 or 1
            lefts[col] = math.min(lefts[col] or b.x, b.x)
        end
    end
    entry.text_left = lefts
    return lefts
end

--- Called by ReaderView after it paints the page (registered as a view module).
function Spotlight:paintTo(bb, x, y)
    if not self:isActive() then return end
    local s = self:currentSentence()
    if not s or self.current.page ~= self:currentPage() then return end
    local g = self:geometry(s)
    local style = self.settings.style
    if style == "band_bar" and self:isNightBright() then
        -- Night mode inverts the whole screen. Inverting the band once more
        -- shows the sentence in day colours (black on white) on the dark page.
        for _i, r in ipairs(g.bands) do
            if r.h > 0 then bb:invertRect(r.x, r.y, r.w, r.h) end
        end
    elseif style == "band_bar" then
        for _i, r in ipairs(g.bands) do
            if r.h > 0 then bb:darkenRect(r.x, r.y, r.w, r.h, self.settings.darkness) end
        end
    elseif style == "underline" then
        for _i, r in ipairs(g.underlines) do
            bb:paintRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_BLACK)
        end
    end
    for _i, r in ipairs(g.bars) do
        bb:paintRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_BLACK)
    end
    self.lit_region = g.region
    self:paintIndicator(bb)
end

---------------------------------------------------------------------------
-- Auto indicator ("Auto · 200 wpm")
---------------------------------------------------------------------------

function Spotlight:indicatorText()
    if not self:isAuto() then return nil end
    return T(_("Auto · %1 wpm"), self:paceWpm())
end

--[[
KOReader's footer takes extra content from plugins
(ReaderFooter:addAdditionalFooterContent), but by default the footer shows
one item at a time, so the content would only show after cycling the footer
to it. So: when the footer is visible and shows all its items at once, the
indicator goes there; otherwise Spotlight draws a small label of its own in
the bottom-right corner, above the footer.
]]
function Spotlight:footerShowsIndicator()
    local footer = self.view.footer
    return footer and footer.addAdditionalFooterContent and self.view.footer_visible
        and footer.settings and footer.settings.all_at_once
end

function Spotlight:updateIndicator()
    local footer = self.view.footer
    if footer and footer.addAdditionalFooterContent then
        if not self.footer_func then
            self.footer_func = function() return self:indicatorText() end
            footer:addAdditionalFooterContent(self.footer_func)
        end
        self.ui:handleEvent(Event:new("RefreshAdditionalContent"))
    end
    -- Our own label: refresh its old and new area.
    local old = self.indicator_region
    self.indicator_region = self:indicatorRegion()
    if old or self.indicator_region then
        self:refresh(old, self.indicator_region, "ui")
    end
end

function Spotlight:indicatorWidget()
    local text = self:indicatorText()
    if not text or self:footerShowsIndicator() then return nil end
    if self.indicator_widget and self.indicator_widget.text == text then
        return self.indicator_widget
    end
    if self.indicator_widget then self.indicator_widget:free() end
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    self.indicator_widget = TextWidget:new{ text = text, face = Font:getFace("ffont", 15) }
    return self.indicator_widget
end

function Spotlight:indicatorRegion()
    local w = self:indicatorWidget()
    if not w then return nil end
    local size = w:getSize()
    local margin = Screen:scaleBySize(8)
    local bottom = Screen:getHeight()
    local footer = self.view.footer
    if self.view.footer_visible and footer and footer.getHeight then
        bottom = bottom - footer:getHeight()
    end
    return Geom:new{
        x = Screen:getWidth() - size.w - margin,
        y = bottom - size.h - Screen:scaleBySize(2),
        w = size.w, h = size.h,
    }
end

function Spotlight:paintIndicator(bb)
    local w = self:indicatorWidget()
    if not w then return end
    local r = self:indicatorRegion()
    w:paintTo(bb, r.x, r.y)
    self.indicator_region = r
end

--[[
Repaint the page and refresh only the union of the old and new highlight.
"ui" is the fastest waveform that shows gray cleanly; "fast" is black and
white only, so it is used when nothing gray is drawn. Neither counts toward
KOReader's "full refresh every N pages" (only "partial" refreshes do), and
page turns keep using KOReader's own refresh, so that setting still applies.
]]
function Spotlight:refresh(old_region, new_region, mode)
    local region
    if old_region and new_region then
        region = old_region:combine(new_region)
    else
        region = old_region or new_region
    end
    if not region then return end
    mode = mode or (self.settings.style == "band_bar" and "ui" or "fast")
    UIManager:setDirty(self.view.dialog, function() return mode, region end)
end

---------------------------------------------------------------------------
-- Turning Spotlight on and off, look settings
---------------------------------------------------------------------------

function Spotlight:setEnabled(on)
    if not self:isSupported() then
        UIManager:show(InfoMessage:new{
            text = _("Spotlight works with reflowable books (EPUB, FB2, HTML, TXT)."),
        })
        return
    end
    if on == self.settings.enabled then return end
    self.settings.enabled = on
    self:saveSettings()
    self:updateKeyCapture()
    if on then
        if self.view.view_mode ~= "page" then
            UIManager:show(InfoMessage:new{
                text = _("Spotlight works in page mode. Switch the book to page mode to use it."),
            })
            return
        end
        self:selectOnPage(self:currentPage())
        local s = self:currentSentence()
        self:refresh(nil, s and self:geometry(s).region, "ui")
        self:startAuto(false)
    else
        local old = self.lit_region
        self:stopAuto()
        self:showSessionPace()
        self.pages = {}
        self.current = nil
        self.lit_region = nil
        self.timing = nil
        self:refresh(old, nil, "ui")
    end
end

function Spotlight:setLook(key, value)
    if self.settings[key] == value then return end
    local old = self.lit_region
    self.settings[key] = value
    self:saveSettings()
    self.geom_version = self.geom_version + 1
    local s = self:isActive() and self:currentSentence()
    self:refresh(old, s and self:geometry(s).region, "ui")
end

---------------------------------------------------------------------------
-- KOReader events
---------------------------------------------------------------------------

-- Event handlers for events other modules also need (ReaderReady, PageUpdate,
-- SaveSettings, CloseDocument...) must not return true.

function Spotlight:onReaderReady()
    if not self:isSupported() then return end
    -- KOReader has already gone back to the last page read; light the
    -- sentence saved for this book if it is on that page.
    self.pending_key = self.ui.doc_settings:readSetting("spotlight_position")
    self.book_pace = self.ui.doc_settings:readSetting("spotlight_pace")
    if self.settings.mode == "auto" and not self.learned then
        -- Auto was on before learning existed (0.3): learn the pace first.
        self.settings.mode = "manual"
        self:saveSettings()
        if self:isActive() then UIManager:nextTick(function() self:startLearning() end) end
    end
    self:updateKeyCapture()
    if self:isActive() then
        self:selectOnPage(self:currentPage())
        -- In Auto mode the light waits for a first tap, so you can find your
        -- place first.
        self:startAuto(true)
    end
end

-- A page turn of any kind (swipe, tap, key, link, TOC, or our own). Runs
-- before the new page is painted.
function Spotlight:onPageUpdate()
    if not self:isActive() then return end
    local s = self:currentSentence()
    self.key_before_update = s and s.key
    local target = self.turn_target
    self.turn_target = nil
    local page = self:currentPage()
    if not target and self.current and self.current.page == page and self.pages[page] then
        -- The page already lit is shown again (KOReader sends this after
        -- opening a book and on redraws): keep the lit sentence.
        return
    end
    self:selectOnPage(page, target or nil)
end

-- Font, size, margins, spacing and other layout changes. ReaderRolling sends
-- PageUpdate first (with the new layout, while our cache is still the old
-- one) and then this, so relight the sentence that was lit before that.
function Spotlight:onDocumentRerendered()
    self:invalidate(self.key_before_update)
    if self:isActive() then
        self:selectOnPage(self:currentPage())
    end
end

function Spotlight:onDocumentPartiallyRerendered()
    self:invalidate()
end

-- Rotation, window resize: a re-render follows.
function Spotlight:onSetDimensions()
    self:invalidate()
end

function Spotlight:onChangeViewMode()
    self:invalidate()
    self:updateKeyCapture()
    if self:isActive() then
        self:selectOnPage(self:currentPage())
        self:startAuto(true)
    else
        self:stopAuto()
    end
end

function Spotlight:onSaveSettings()
    if not self:isSupported() then return end
    local s = self:currentSentence()
    if s then
        self.ui.doc_settings:saveSetting("spotlight_position", s.key)
    end
    self:flushStore()
end

function Spotlight:onCloseDocument()
    if not self:isSupported() then return end
    self.timing = nil
    self:stopAuto()
    self:showSessionPace()
    self:saveStatsSession(true)
    local footer = self.view.footer
    if self.footer_func and footer and footer.removeAdditionalFooterContent then
        footer:removeAdditionalFooterContent(self.footer_func)
        self.footer_func = nil
    end
    self:flushStore()
end

function Spotlight:onSuspend()
    if not self:isSupported() then return end
    self.timing = nil -- time asleep is not reading time
    if self:isAuto() then self:pauseAuto("sleep") end
    self:saveStatsSession(false) -- in case the book is never closed
    self:flushStore()
end

-- After waking up, Manual timing starts over; Auto stays paused until a tap.
function Spotlight:onResume()
    -- A long sleep ends the reading session; the next reading starts a new one.
    local session = self.stats_session
    if session and session:idleSeconds(os.time()) > cfg.session_break_s then
        self:saveStatsSession(true)
    end
    if self:isActive() and not self:isAuto() then
        self:startTiming(self:currentSentence(), true)
    end
end

function Spotlight:onDispatcherRegisterActions()
    Dispatcher:registerAction("spotlight_toggle", {
        category = "none", event = "SpotlightToggle", title = _("Toggle Spotlight"), reader = true,
    })
    Dispatcher:registerAction("spotlight_next", {
        category = "none", event = "SpotlightNext", title = _("Spotlight: next sentence"), reader = true,
    })
    Dispatcher:registerAction("spotlight_prev", {
        category = "none", event = "SpotlightPrev", title = _("Spotlight: previous sentence"), reader = true,
    })
    Dispatcher:registerAction("spotlight_toggle_auto", {
        category = "none", event = "SpotlightToggleAuto", title = _("Spotlight: toggle Auto"), reader = true,
    })
    Dispatcher:registerAction("spotlight_faster", {
        category = "none", event = "SpotlightFaster", title = _("Spotlight: faster (+5 wpm)"), reader = true,
    })
    Dispatcher:registerAction("spotlight_slower", {
        category = "none", event = "SpotlightSlower", title = _("Spotlight: slower (−5 wpm)"), reader = true,
    })
    Dispatcher:registerAction("spotlight_speed_panel", {
        category = "none", event = "SpotlightSpeedPanel", title = _("Spotlight: speed panel"), reader = true,
    })
    Dispatcher:registerAction("spotlight_stats", {
        category = "none", event = "SpotlightStats", title = _("Spotlight: show stats"), reader = true,
    })
end

function Spotlight:onSpotlightToggle()
    self:setEnabled(not (self.settings and self.settings.enabled))
    return true
end

function Spotlight:onSpotlightNext()
    if self:isActive() then self:onSentenceInput(1) end
    return true
end

function Spotlight:onSpotlightPrev()
    if self:isActive() then self:onSentenceInput(-1) end
    return true
end

function Spotlight:onSpotlightToggleAuto()
    if not self:isSupported() then return true end
    if not self.settings.enabled then self:setEnabled(true) end
    self:setMode(self.settings.mode == "auto" and "manual" or "auto")
    return true
end

function Spotlight:onSpotlightFaster()
    if self:isSupported() then self:setWpm(self:paceWpm() + cfg.wpm_step) end
    return true
end

function Spotlight:onSpotlightSlower()
    if self:isSupported() then self:setWpm(self:paceWpm() - cfg.wpm_step) end
    return true
end

function Spotlight:onSpotlightStats()
    if self:isSupported() then self:showStats() end
    return true
end

function Spotlight:onSpotlightSpeedPanel()
    if self:isSupported() then self:showSpeedPanel() end
    return true
end

--- The speed panel (speedpanel.lua), modelled on KOReader's frontlight panel.
function Spotlight:showSpeedPanel()
    local SpeedPanel = loadModule("speedpanel")
    UIManager:show(SpeedPanel:new{
        value = self:paceWpm(),
        min = cfg.min_wpm,
        max = cfg.max_wpm,
        step = cfg.wpm_step,
        on_change = function(wpm) self:setWpm(wpm) end,
    })
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

function Spotlight:addToMainMenu(menu_items)
    if not self:isSupported() then
        local why = self.startup_error
            and T(_("Spotlight %1 could not start:\n\n%2\n\nThe same message is in koreader/crash.log."), VERSION, self.startup_error)
            or _("Spotlight works with reflowable books (EPUB, FB2, HTML, TXT, MOBI). This book is not one of them.")
        menu_items.spotlight = {
            text = self.startup_error and _("Spotlight (could not start)") or _("Spotlight (not for this book)"),
            sorting_hint = "navi",
            keep_menu_open = true,
            callback = function() UIManager:show(InfoMessage:new{ text = why }) end,
        }
        return
    end
    menu_items.spotlight = {
        text = _("Spotlight"),
        sorting_hint = "navi",
        sub_item_table = {
            {
                text = _("Spotlight on"),
                checked_func = function() return self.settings.enabled end,
                callback = function() self:setEnabled(not self.settings.enabled) end,
            },
            {
                text_func = function() return T(_("Mode: %1"), labelFor(MODES, self.settings.mode)) end,
                sub_item_table = self:getModeMenu(),
            },
            {
                text_func = function()
                    local pace, source = self:currentPace()
                    local whose = ({ book = _("this book"), yours = _("your pace"), default = _("not learned yet") })[source]
                    return T(_("Speed: %1 wpm (%2)"), pace.wpm, whose)
                end,
                keep_menu_open = true,
                callback = function() self:showSpeedPanel() end,
            },
            {
                text = _("Auto-adjust speed"),
                checked_func = function() return self.settings.auto_adjust end,
                callback = function()
                    self.settings.auto_adjust = not self.settings.auto_adjust
                    self:saveSettings()
                end,
                help_text = _("In Auto mode, every 15 sentences: 3 or more holds or backs slow the light by 5 %. No stops and a skip-ahead speed it up by 5 %. No stops and no skips twice in a row speed it up by 2 %. Changes show only in the Auto indicator, and are kept for this book."),
            },
            {
                text = _("Look"),
                sub_item_table = self:getLookMenu(),
            },
            {
                text = _("Learn my pace again"),
                keep_menu_open = true,
                callback = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Forget your reading timings and learned pace, and learn it again from your next sentences in Manual mode?\n\nThis book's own speed is reset too; other books keep theirs."),
                        ok_text = _("Learn again"),
                        ok_callback = function() self:relearn() end,
                    })
                end,
            },
            {
                text = _("Stats"),
                sub_item_table = {
                    {
                        text = _("Show stats"),
                        keep_menu_open = true,
                        callback = function() self:showStats() end,
                    },
                    {
                        text = _("Export stats (JSON)"),
                        keep_menu_open = true,
                        callback = function() self:exportStats() end,
                        help_text = _("Copies every reading session to spotlight/spotlight_stats.json in your home folder. On a Kindle that is the spotlight folder at the top of its USB storage."),
                    },
                },
            },
        },
    }
end

function Spotlight:getModeMenu()
    local items = {}
    for _i, item in ipairs(MODES) do
        items[#items + 1] = {
            text = item[2],
            radio = true,
            checked_func = function() return self.settings.mode == item[1] end,
            callback = function() self:setMode(item[1]) end,
        }
    end
    items[1].help_text = _("You move the light: tap right or press the forward key for the next sentence, tap left or press back for the previous one.")
    items[2].help_text = _("The light moves on its own at your pace. Hold anywhere to pause; let go to continue. Tap right to skip ahead, tap left to go back. The first time, Spotlight learns your pace from Manual reading first.")
    items[2].text_func = function()
        if self.learned then return _("Auto") end
        local n = Pace.learningProgress(self.samples)
        return T(_("Auto (learning your pace: %1 of %2 sentences)"), math.min(n, cfg.learn_min_sentences), cfg.learn_min_sentences)
    end
    return items
end

function Spotlight:getLookMenu()
    local style_items = {}
    for _i, item in ipairs(STYLES) do
        style_items[#style_items + 1] = {
            text = item[2],
            radio = true,
            checked_func = function() return self.settings.style == item[1] end,
            callback = function() self:setLook("style", item[1]) end,
        }
    end
    local darkness_items = {}
    for _i, item in ipairs(DARKNESS) do
        darkness_items[#darkness_items + 1] = {
            text = item[2],
            radio = true,
            checked_func = function() return self.settings.darkness == item[1] end,
            callback = function() self:setLook("darkness", item[1]) end,
        }
    end
    local night_items = {}
    for _i, item in ipairs(NIGHT_LOOKS) do
        night_items[#night_items + 1] = {
            text = item[2],
            radio = true,
            checked_func = function() return self.settings.night_look == item[1] end,
            callback = function() self:setLook("night_look", item[1]) end,
        }
    end
    local width_items = {}
    for _i, w in ipairs(BAR_WIDTHS) do
        width_items[#width_items + 1] = {
            text = T(_("%1 px"), w),
            radio = true,
            checked_func = function() return self.settings.bar_width == w end,
            callback = function() self:setLook("bar_width", w) end,
        }
    end
    return {
        {
            text_func = function() return T(_("Style: %1"), labelFor(STYLES, self.settings.style)) end,
            sub_item_table = style_items,
        },
        {
            text_func = function() return T(_("Band darkness: %1"), labelFor(DARKNESS, self.settings.darkness)) end,
            enabled_func = function() return self.settings.style == "band_bar" end,
            sub_item_table = darkness_items,
        },
        {
            text_func = function() return T(_("Bar width: %1 px"), self.settings.bar_width) end,
            enabled_func = function() return self.settings.style ~= "underline" end,
            sub_item_table = width_items,
        },
        {
            text_func = function()
                return T(_("In night mode: %1"), labelFor(NIGHT_LOOKS, self.settings.night_look))
            end,
            enabled_func = function() return self.settings.style == "band_bar" end,
            help_text = _("How the lit sentence looks when KOReader's night mode is on. Bright sentence shows it in day colours, black on white, on the dark page. Soft glow keeps the dim band. Spotlight follows night mode by itself."),
            sub_item_table = night_items,
        },
    }
end

return Spotlight
