-- Spotlight in real KOReader on a real EPUB. Run through run.sh.
-- Prints PASS/FAIL per check; exits non-zero if anything failed.
local H = dofile(arg[0]:match("^(.*)/[^/]*$") .. "/boot.lua")
local book = arg[1]
local start_page = tonumber(arg[2]) or 20
G_reader_settings:saveSetting("document_metadata_folder", "dir") -- book settings go in the throwaway folder

local UIManager, Event = H.UIManager, H.Event
local W, Hh = H.Screen:getWidth(), H.Screen:getHeight()
local RIGHT = { W * 0.75, Hh * 0.5 }
local LEFT = { W * 0.1, Hh * 0.5 }

-- A clock the test moves forward, so timings look like real reading.
local real_now, offset = H.time.now, 0
H.time.now = function() return real_now() + offset end
local function wait(ms) offset = offset + ms * 1000 end

-- Errors KOReader logs (a failing menu, a failing event handler...).
local errors = {}
local log_err = H.logger.err
H.logger.err = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    errors[#errors + 1] = table.concat(parts, " ")
    return log_err(...)
end

-- Refreshes UIManager queues for the screen, after its own promotions.
local refreshes = {}
local orig_refresh = UIManager._refresh
UIManager._refresh = function(self, mode, region, dither)
    orig_refresh(self, mode, region, dither)
    local e = self._refresh_stack[#self._refresh_stack]
    if e then refreshes[#refreshes + 1] = { mode = e.mode, region = e.region } end
end

local failures = 0
local function check(cond, what, detail)
    print((cond and "PASS  " or "FAIL  ") .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    if not cond then failures = failures + 1 end
end
local function closePopups(ui)
    while UIManager:getTopmostVisibleWidget() ~= ui do UIManager:close(UIManager:getTopmostVisibleWidget()) end
end
local function paint() refreshes = {}; H.paint() end

local ui = H.open(book)
closePopups(ui)
local sp = ui.spotlight
local doc = ui.document
check(sp ~= nil, "plugin loaded")

print("== menu")
ui.menu:setUpdateItemTable()
check(ui.menu.tab_item_table[1][1].id == "spotlight", "Spotlight is the first entry of the first tab")
check(#errors == 0, "menu builds without errors", errors[1])

print("== turn on")
ui:handleEvent(Event:new("GotoPage", start_page)); paint()
sp:setEnabled(true); paint()
local function lit() return sp:currentSentence() end
check(lit() ~= nil, "a sentence is lit", lit() and lit().text:sub(1, 50))
check(#refreshes == 1 and refreshes[1].mode == "ui" and refreshes[1].region.h < Hh / 2,
    "turning on refreshes only the sentence, with 'ui'", refreshes[1] and (refreshes[1].mode .. " " .. refreshes[1].region.h .. "px tall"))
print("shots:", H.shot("01-on"))

print("== taps")
local page = doc:getCurrentPage()
local idx = sp.current.index
wait(300 * lit().words)
check(H.tap(ui, RIGHT[1], RIGHT[2]) == true, "tap right is handled by Spotlight")
paint()
check(doc:getCurrentPage() == page and sp.current.index == idx + 1, "tap right: next sentence, same page")
H.tap(ui, LEFT[1], LEFT[2]); paint()
check(sp.current.index == idx, "tap left: previous sentence")
H.tap(ui, RIGHT[1], RIGHT[2]); paint()
check(#refreshes == 1 and refreshes[1].mode == "ui", "a sentence step is one 'ui' refresh", refreshes[1] and refreshes[1].mode)

print("== invert taps")
local menu_items = {}
sp:addToMainMenu(menu_items)
local invert_item
for _i, item in ipairs(menu_items.spotlight.sub_item_table) do
    if item.text_func and item.text_func() == "Invert taps" then invert_item = item end
end
check(invert_item ~= nil, "the menu has Invert taps")
invert_item.callback()
idx = sp.current.index
H.tap(ui, W * 0.1, Hh * 0.5); paint()
check(sp.current.index == idx + 1, "inverted: a tap on the left goes forward")
H.tap(ui, W * 0.9, Hh * 0.5); paint()
check(sp.current.index == idx, "inverted: a tap on the right quarter goes back")
invert_item.callback()
check(not sp.settings.invert_taps, "and it switches off again")

print("== across a page break")
local crossed, steps = nil, 0
while steps < 120 and not crossed do
    local s = lit()
    wait(300 * (s and s.words or 5))
    local p = doc:getCurrentPage()
    local was_split = s and s.ends_after
    H.tap(ui, RIGHT[1], RIGHT[2]); paint()
    steps = steps + 1
    if was_split then
        crossed = { from = p, key = s.key }
        check(doc:getCurrentPage() > p and lit() and lit().key == s.key and lit().starts_before,
            "a split sentence continues on the next page", lit() and lit().text:sub(1, 50))
        print("shots:", H.shot("02-continued"))
    end
end
check(crossed ~= nil, "found a sentence split by a page break")
if crossed then
    H.tap(ui, LEFT[1], LEFT[2]); paint()
    check(doc:getCurrentPage() == crossed.from and lit().key == crossed.key and lit().ends_after,
        "back: the start of the split sentence on the previous page")
end
check(#sp.samples > 0, "reading timings are kept", #sp.samples .. " kept")

print("== KOReader's own taps and holds")
H.tap(ui, W * 0.75, Hh * 0.04)
check(ui.menu.menu_container ~= nil, "top strip opens the menu")
ui.menu:onCloseReaderMenu(); ui:handleEvent(Event:new("CloseConfigMenu")); closePopups(ui)
H.tap(ui, W * 0.5, Hh * 0.89)
check(ui.config.config_dialog ~= nil and UIManager:getTopmostVisibleWidget() ~= ui, "bottom strip opens the settings bar")
closePopups(ui); paint()
local box = sp:geometry(lit()).bands[1]
H.gesture(ui, { ges = "hold", pos = { x = box.x + box.w / 2, y = box.y + box.h / 2, w = 0, h = 0 } })
H.gesture(ui, { ges = "hold_release", pos = { x = box.x + box.w / 2, y = box.y + box.h / 2, w = 0, h = 0 } })
check(ui.highlight.selected_text ~= nil, "hold selects a word (KOReader's dictionary and highlighting)")
closePopups(ui); ui.highlight:clear(); paint()

print("== swipe and keys")
page = doc:getCurrentPage()
H.gesture(ui, { ges = "swipe", direction = "west", distance = 400, pos = { x = W * 0.7, y = Hh * 0.5, w = 0, h = 0 } })
paint()
check(doc:getCurrentPage() == page + 1 and sp.current.index == 1, "swipe: next page, first sentence lit")
page, idx = doc:getCurrentPage(), sp.current.index
H.key(ui, "RPgFwd"); paint()
check(doc:getCurrentPage() == page and sp.current.index == idx + 1, "page key moves the sentence, not the page")

print("== layout change")
local text = lit().text
local size = doc.configurable.font_size
ui:handleEvent(Event:new("SetFontSize", size + 4)); paint()
check(lit() and lit().text == text, "bigger font: same sentence lit")
print("shots:", H.shot("03-bigger-font"))
ui:handleEvent(Event:new("SetFontSize", size)); paint()

print("== night mode")
local RenderImage = require("ui/renderimage")
-- Brightness (0 black .. 255 white) of a screen point as you see it, read
-- back from a screenshot (KOReader saves night mode as shown).
local function brightness(name, x, y)
    local img = RenderImage:renderImageFile(H.shot(name), false)
    local v = img:getPixel(math.floor(x), math.floor(y)):getColor8().a
    img:free()
    return v
end
local g = sp:geometry(lit())
local band, bar = g.bands[1], g.bars[1]
local inside = { band.x + 1, band.y + band.h / 2 }        -- band padding, left of the first letter
local outside = { math.max(1, bar.x - 10), band.y + band.h / 2 } -- page margin, left of the bar
local text_left = sp:textLeft(sp.pages[sp.current.page])[1]
check(bar.x + bar.w < text_left and text_left - (bar.x + bar.w) <= H.Screen:scaleBySize(12),
    "the bar sits just left of the page's text", "bar ends at " .. (bar.x + bar.w) .. ", text starts at " .. text_left)
ui:handleEvent(Event:new("ToggleNightMode")); paint()
check(sp.settings.night_look == "bright", "night look defaults to Bright sentence")
local v_in, v_out = brightness("05-night-bright", inside[1], inside[2]), brightness("05-night-bright", outside[1], outside[2])
check(v_in >= 0xC0 and v_out <= 0x40, "night, Bright sentence: white band on a dark page", "band " .. v_in .. ", page " .. v_out)
check(H.Screen.night_mode == true, "KOReader night mode is on")
sp:setLook("night_look", "glow"); paint()
check(#refreshes == 1 and refreshes[1].mode == "ui", "changing the night look refreshes only the sentence", refreshes[1] and refreshes[1].mode)
v_in = brightness("06-night-glow", inside[1], inside[2])
check(v_in > 0x10 and v_in < 0x80, "night, Soft glow: dim gray band", "band " .. v_in)
sp:setLook("night_look", "bright")
ui:handleEvent(Event:new("ToggleNightMode")); paint()
v_in, v_out = brightness("07-day", inside[1], inside[2]), brightness("07-day", outside[1], outside[2])
check(v_in > 0xA0 and v_in < 0xF0 and v_out >= 0xF0, "back to day: light gray band on white", "band " .. v_in .. ", page " .. v_out)

local Pace = dofile(arg[0]:match("^(.*)/[^/]*$") .. "/../../spotlight.koplugin/pace.lua")
local cfg = Pace.config
local function runTimers() UIManager:_checkTasks(); paint() end
local function due() return sp.pacer:untilDue(H.time.to_ms(H.time.now())) end
local function stepTime(ms) wait(ms); runTimers() end
local function isTop(w) return UIManager:getTopmostVisibleWidget() == w end

print("== learning your pace")
closePopups(ui)
ui:handleEvent(Event:new("GotoPage", start_page + 30)); paint()
local samples_before = #sp.samples
sp:setMode("auto"); paint()
local top = UIManager:getTopmostVisibleWidget()
check(sp.settings.mode == "manual" and sp.learning, "choosing Auto first starts learning, in Manual mode")
check(top ~= ui and top.text and top.text:find("learns your pace"), "and says so")
closePopups(ui); paint()
-- Read like a steady reader: 0.5 s per sentence plus 280 ms a word.
local popup
for _i = 1, 80 do
    local s = lit()
    wait(500 + s.words * 280)
    H.tap(ui, RIGHT[1], RIGHT[2]); paint()
    top = UIManager:getTopmostVisibleWidget()
    if top ~= ui then popup = top; break end
end
check(popup and popup.text and popup.text:find("^Auto is ready%. You read about %d+ words a minute"),
    "after about 40 sentences: \"Auto is ready\"", popup and popup.text)
local said = popup and tonumber(popup.text:match("about (%d+) words"))
check(said and math.abs(said - 214) <= 15, "it measured the pace (about 214 wpm)", said)
check(#sp.samples >= cfg.learn_min_sentences, "from 40 or more valid timings (earlier Manual reading counts too)",
    #sp.samples .. " in all, " .. (#sp.samples - samples_before) .. " just now")
print("shots:", H.shot("08-auto-is-ready"))
popup.ok_callback()
UIManager:close(popup); paint()
check(sp:isAuto() and select(2, sp:currentPace()) == "yours", "Start Auto: Auto runs at your learned pace", sp:paceWpm() .. " wpm")

print("== Auto mode")
ui:handleEvent(Event:new("GotoPage", start_page)); paint()
sp:setMode("auto"); paint()
check(sp:isAuto() and sp.pacer:isRunning(), "Auto starts")
check(require("pluginshare").pause_auto_suspend == true, "auto-suspend is held off while Auto runs")
local text0 = lit().text
stepTime(due() - 50)
check(lit().text == text0, "the light stays until its time is up")
stepTime(60)
check(lit().text ~= text0, "then moves on by itself", lit().text:sub(1, 50))
check(#refreshes == 1 and refreshes[1].mode == "ui" and refreshes[1].region.h < Hh / 2,
    "an automatic step refreshes only the sentence area", refreshes[1] and refreshes[1].mode)
print("shots:", H.shot("08-auto"))

-- Hold: finger down pauses, KOReader's dictionary/highlight stays closed.
local text1 = lit().text
local hb = sp:geometry(lit()).bands[1]
local hpos = { x = hb.x + hb.w / 2, y = hb.y + hb.h / 2, w = 0, h = 0 }
stepTime(300)
local before_hold = due()
H.gesture(ui, { ges = "touch", pos = hpos })
check(sp.pacer:isPaused(), "finger down pauses at once")
H.gesture(ui, { ges = "hold", pos = hpos })
stepTime(30000)
check(lit().text == text1, "held for 30 s: the light stays")
check(ui.highlight.selected_text == nil and isTop(ui), "the hold opens no dictionary or highlight")
H.gesture(ui, { ges = "hold_release", pos = hpos })
check(sp.pacer:isRunning() and math.abs(due() - (before_hold + cfg.hold_resume_grace_ms)) < 30,
    "let go: the time that was left plus 0.5 s", due() .. " ms")

-- Quick tap right: skip ahead.
H.gesture(ui, { ges = "touch", pos = { x = RIGHT[1], y = RIGHT[2], w = 0, h = 0 } })
H.tap(ui, RIGHT[1], RIGHT[2]); paint()
check(lit().text ~= text1 and sp.session.skips == 1, "a quick tap right skips ahead")

-- Let it run over a page break.
local p_auto = doc:getCurrentPage()
local n = 0
while doc:getCurrentPage() == p_auto and n < 60 do stepTime(due() + 1); n = n + 1 end
check(doc:getCurrentPage() == p_auto + 1, "it turns the page by itself", n .. " sentences")
check(due() >= cfg.page_turn_grace_ms, "the first sentence after the turn gets the extra 0.8 s", due() .. " ms")

-- A menu over the page holds the light.
local text2 = lit().text
H.tap(ui, W * 0.75, Hh * 0.04)
stepTime(due() + 3000)
check(lit().text == text2, "with the menu open the light waits")
ui.menu:onCloseReaderMenu(); ui:handleEvent(Event:new("CloseConfigMenu")); closePopups(ui)
stepTime(cfg.blocked_poll_s * 1000 + 10)
stepTime(cfg.dialog_resume_grace_ms + 10)
check(lit().text ~= text2, "after the menu closes it carries on")

print("== speed panel")
sp:showSpeedPanel(); paint()
local panel = UIManager:getTopmostVisibleWidget()
check(panel and panel.name == "SpotlightSpeedPanel", "the speed panel opens")
print("shots:", H.shot("09-speed-panel"))
local wpm0 = sp:paceWpm()
local function panelTap(x, y)
    panel:handleEvent(Event:new("Gesture", { ges = "tap", pos = H.Geom:new{ x = x, y = y, w = 0, h = 0 }, time = H.time.now() }))
    paint()
end
local pd = panel.plus.dimen
panelTap(pd.x + pd.w / 2, pd.y + pd.h / 2)
check(sp:paceWpm() == wpm0 + 5, "+ adds 5 wpm", sp:paceWpm())
local md = panel.minus.dimen
panelTap(md.x + md.w / 2, md.y + md.h / 2)
panelTap(md.x + md.w / 2, md.y + md.h / 2)
check(sp:paceWpm() == wpm0 - 5, "− takes 5 wpm off", sp:paceWpm())
local sd = panel.slider.dimen
panelTap(sd.x + sd.w * 0.5, sd.y + sd.h / 2)
check(math.abs(sp:paceWpm() - 240) <= 5, "tapping the middle of the slider sets about 240 wpm", sp:paceWpm())
check(select(2, sp:currentPace()) == "book", "the change is kept for this book")
print("shots:", H.shot("10-speed-panel-240"))
panelTap(5, 5)
check(isTop(ui), "tapping outside closes the panel")

print("== indicator")
paint()
local label = sp.indicator_widget
check(label and label.text == "Auto · " .. sp:paceWpm() .. " wpm", "the indicator shows Auto and the speed", label and label.text)
check(sp.view.footer.additional_footer_content and #sp.view.footer.additional_footer_content >= 1, "the footer has the indicator too (shown when it lists all items)")
UIManager:setDirty("all", "full"); paint()
print("shots:", H.shot("11-indicator"))

print("== auto-adjust")
sp.adjuster = Pace.newAdjuster()
local wpm_a = sp:paceWpm()
-- Three holds early in a window of 15 sentences (a sentence split by a page
-- break counts once), then let the window run out.
local held_at = {}
for _i = 1, 40 do
    if sp:paceWpm() ~= wpm_a then break end
    local c = sp.adjuster.count
    if (c == 2 or c == 6 or c == 10) and not held_at[c] then
        held_at[c] = true
        local b = sp:geometry(lit()).bands[1]
        local p = { x = b.x + b.w / 2, y = b.y + b.h / 2, w = 0, h = 0 }
        H.gesture(ui, { ges = "touch", pos = p })
        H.gesture(ui, { ges = "hold", pos = p })
        stepTime(1500)
        H.gesture(ui, { ges = "hold_release", pos = p })
    end
    stepTime(due() + 1)
end
check(sp:paceWpm() == Pace.adjustedWpm(wpm_a, cfg.adjust_slower), "3 holds in 15 sentences: 5 % slower",
    wpm_a .. " -> " .. sp:paceWpm())
check(isTop(ui), "no popup about it")
check(sp.indicator_widget and sp.indicator_widget.text == "Auto · " .. sp:paceWpm() .. " wpm", "the indicator shows the new speed")

local session_start = sp.auto_session and sp.auto_session.start_wpm
sp:setMode("manual"); paint()
check(not sp.pacer:isRunning() and not sp.pacer:isPaused(), "Manual mode: the pacer stops")
check(require("pluginshare").pause_auto_suspend ~= true, "auto-suspend is allowed again")
top = UIManager:getTopmostVisibleWidget()
check(top ~= ui and top.text == ("Started at " .. session_start .. ", ended at " .. sp:paceWpm() .. " words a minute."),
    "turning Auto off shows how the speed went", top and top.text)
print("shots:", H.shot("12-session-pace"))
closePopups(ui); paint()

print("== close and reopen")
text = lit().text
ui:onClose()
UIManager:close(ui)
ui = H.open(book)
closePopups(ui)
sp = ui.spotlight
check(sp:currentSentence() and sp:currentSentence().text == text, "the sentence is restored when the book opens")

print("== stats")
local rapidjson = require("rapidjson")
local util = require("util")
local stats_path = H.DataStorage:getSettingsDir() .. "/spotlight_stats.json"
local stats_text = util.readFromFile(stats_path, "r")
local stats_data = stats_text and rapidjson.decode(stats_text)
check(stats_data and stats_data.format == "spotlight-sessions" and #stats_data.sessions >= 1,
    "closing the book saved the session to spotlight_stats.json", stats_data and #stats_data.sessions)
local rec = stats_data and stats_data.sessions[1]
if rec then
    print(string.format("  session: %s, %d s active (%d Manual, %d Auto), %d sentences, %d words, %d wpm, holds %d, backs %d, skips %d, pace %d -> %d, %d adjustments",
        rec.book_title, rec.active_seconds, rec.manual_seconds, rec.auto_seconds, rec.sentences, rec.words,
        rec.average_wpm, rec.holds, rec.backs, rec.skip_aheads, rec.starting_pace_wpm, rec.ending_pace_wpm, rec.auto_adjust_changes))
    check(rec.book_title ~= "" and rec.sentences > 40 and rec.words > rec.sentences,
        "it has the book, the sentences and the words")
    check(rec.manual_seconds > 0 and rec.auto_seconds > 0 and rec.active_seconds == rec.manual_seconds + rec.auto_seconds,
        "reading time is split between Manual and Auto")
    check(rec.holds >= 1 and rec.skip_aheads >= 1 and rec.backs >= 1 and rec.auto_adjust_changes >= 1,
        "holds, skips, backs and auto-adjust changes are counted")
    check(rec.date == os.date("%Y-%m-%d"), "dated today", rec.date)
end
sp = ui.spotlight
sp:showStats(); paint()
local page = UIManager:getTopmostVisibleWidget()
check(page ~= ui and page.title == "Spotlight stats", "the stats screen opens")
print("shots:", H.shot("13-stats"))
closePopups(ui); paint()
G_reader_settings:saveSetting("home_dir", H.DataStorage:getDataDir() .. "/home") -- not your real home folder
local exported, export_path = sp:exportStats()
local exported_data = exported and rapidjson.decode(util.readFromFile(export_path, "r"))
check(exported_data and #exported_data.sessions == #stats_data.sessions + 0 or (exported_data and #exported_data.sessions >= 1),
    "export writes a readable copy to <home>/spotlight/spotlight_stats.json", export_path)
closePopups(ui); paint()

print("== turn off")
sp:setEnabled(false); paint()
check(ui.rolling.key_events.GotoNextView.is_inactive == nil, "page keys are KOReader's again")
page = ui.document:getCurrentPage()
check(H.tap(ui, RIGHT[1], RIGHT[2]) and ui.document:getCurrentPage() == page + 1, "a tap turns the page as usual")
print("shots:", H.shot("04-off"))

check(#errors == 0, "no errors logged", errors[1])
print(string.format("Done: %d failed", failures))
os.exit(failures == 0 and 0 or 1)
