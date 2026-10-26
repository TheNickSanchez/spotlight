-- Renders the README images in real KOReader (headless, Paperwhite-sized).
-- Run through screenshots.sh. Writes PNGs and raw frames (PGM) to arg[2].
local H = dofile(arg[0]:match("^(.*)/[^/]*$") .. "/boot.lua")
local book, out = arg[1], arg[2]
G_reader_settings:saveSetting("document_metadata_folder", "dir")

local UIManager, Event = H.UIManager, H.Event
local BB = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local W, Hh = H.Screen:getWidth(), H.Screen:getHeight()

-- A learned pace, so Auto can be shown without reading 40 sentences first.
local LuaSettings = require("luasettings")
local store = LuaSettings:open(H.DataStorage:getSettingsDir() .. "/spotlight.lua")
store:saveSetting("learned", true)
store:saveSetting("model", { wpm = 214, pause_ms = 450, n = 60 })
store:saveSetting("manual_samples", {})
store:flush()

local function shot(name)
    local path = out .. "/" .. name .. ".png"
    H.Screen:shot(path)
    print("wrote", path)
    return path
end
local function paint() H.paint() end
local function repaintAll() UIManager:setDirty("all", "full"); paint() end
local function closePopups(ui)
    while UIManager:getTopmostVisibleWidget() ~= ui do UIManager:close(UIManager:getTopmostVisibleWidget()) end
end

--- Save the screen as a half-size 8-bit gray PGM (a GIF frame).
local function frame(name)
    local img = RenderImage:renderImageFile(shot("frame-" .. name), false)
    local w, h = math.floor(img:getWidth() / 2), math.floor(img:getHeight() / 2)
    local bytes = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sum = 0
            for dy = 0, 1 do
                for dx = 0, 1 do
                    sum = sum + img:getPixel(2 * x + dx, 2 * y + dy):getColor8().a
                end
            end
            bytes[#bytes + 1] = string.char(math.floor(sum / 4))
        end
    end
    img:free()
    local f = io.open(out .. "/frame-" .. name .. ".pgm", "wb")
    f:write(string.format("P5\n%d %d\n255\n", w, h), table.concat(bytes))
    f:close()
end

--- Stack crops of several screenshots, each under a label.
local function stack(name, panels, crop_y, crop_h)
    local label_h = 96
    local comp = BB.new(W, #panels * (crop_h + label_h), BB.TYPE_BB8)
    comp:fill(BB.COLOR_WHITE)
    local face = Font:getFace("cfont", 22)
    for i, p in ipairs(panels) do
        local y = (i - 1) * (crop_h + label_h)
        local tw = TextWidget:new{ text = p.label, face = face, bold = true }
        tw:paintTo(comp, 24, y + 22)
        tw:free()
        local img = RenderImage:renderImageFile(p.path, false)
        comp:blitFrom(img, 0, y + label_h, 0, crop_y, W, crop_h)
        img:free()
    end
    local path = out .. "/" .. name .. ".png"
    comp:writePNG(path)
    print("wrote", path)
end

local ui = H.open(book)
closePopups(ui)
local sp = ui.spotlight
local doc = ui.document

-- Find the first line of dialogue in chapter 1.
local target_page, target_idx
for page = 30, 120 do
    for i, s in ipairs(sp:buildPage(page).sentences) do
        if s.text:find("Netherfield Park is let at last", 1, true) and not s.starts_before then
            target_page, target_idx = page, i
            break
        end
    end
    if target_page then break end
end
assert(target_page, "sentence not found")
sp.pages = {}
ui:handleEvent(Event:new("GotoPage", target_page)); paint()
sp:setEnabled(true); paint()
local function lightIndex(i) sp:light(doc:getCurrentPage(), i); paint() end
lightIndex(target_idx)
closePopups(ui); repaintAll()

-- 1. Hero: day, then the light moving (GIF frames).
shot("hero-day")
for step = 0, 5 do
    lightIndex(target_idx + step)
    repaintAll()
    frame(string.format("%02d", step))
end

-- 2. Night mode, Bright sentence.
lightIndex(target_idx)
ui:handleEvent(Event:new("ToggleNightMode")); repaintAll()
shot("hero-night")
ui:handleEvent(Event:new("ToggleNightMode")); repaintAll()

-- 3. The looks, side by side, on a sentence of two or three lines.
local g = sp:geometry(sp:currentSentence())
local crop_y = math.max(0, g.region.y - 70)
local crop_h = g.region.h + 140
local looks = {}
local function look(label, style, night, night_look)
    sp:setLook("style", style)
    sp:setLook("night_look", night_look or "bright")
    if night then ui:handleEvent(Event:new("ToggleNightMode")) end
    repaintAll()
    looks[#looks + 1] = { label = label, path = shot("look-" .. #looks) }
    if night then ui:handleEvent(Event:new("ToggleNightMode")); repaintAll() end
end
look("Band and bar (default)", "band_bar")
look("Bar only", "bar")
look("Underline only", "underline")
look("Night mode: Bright sentence (default)", "band_bar", true, "bright")
look("Night mode: Soft glow", "band_bar", true, "glow")
sp:setLook("style", "band_bar"); sp:setLook("night_look", "bright")
stack("looks", looks, crop_y, crop_h)

-- 4. The menu, open on Spotlight.
ui.menu:onShowMenu(1)
paint()
local tm = ui.menu.menu_container and ui.menu.menu_container[1]
if tm and tm.onMenuSelect then
    tm:onMenuSelect(ui.menu.tab_item_table[1][1])
    paint()
end
repaintAll()
shot("menu")
ui.menu:onCloseReaderMenu(); ui:handleEvent(Event:new("CloseConfigMenu")); closePopups(ui); repaintAll()

-- 5. "Auto is ready".
sp:paceLearned(); paint()
shot("auto-ready")
closePopups(ui); repaintAll()

-- 6. Auto mode with its indicator, and the speed panel.
sp:setMode("auto")
lightIndex(target_idx + 2)
repaintAll()
shot("auto")
sp:showSpeedPanel(); paint()
shot("speed-panel")
closePopups(ui); repaintAll()
sp:setMode("manual")
closePopups(ui) -- the "Started at…, ended at…" message

-- 7. The stats screen, with sample sessions (made up for the picture).
local rapidjson = require("rapidjson")
local sessions = {}
local function day(n) return os.date("%Y-%m-%d", os.time() - n * 86400) end
local samples = {
    -- days ago, minutes, sentences, words, holds, backs
    { 0, 34, 405, 7420, 9, 6 }, { 1, 28, 330, 5710, 11, 9 }, { 2, 41, 470, 8380, 12, 10 },
    { 4, 22, 260, 4520, 8, 7 }, { 5, 30, 350, 6090, 12, 10 }, { 6, 18, 200, 3380, 9, 6 },
    { 8, 25, 280, 4610, 12, 11 }, { 10, 31, 340, 5590, 15, 12 }, { 12, 20, 230, 3700, 10, 9 },
    { 15, 26, 290, 4580, 14, 12 }, { 19, 35, 380, 6000, 18, 15 }, { 24, 15, 170, 2610, 9, 8 },
    { 31, 20, 210, 3150, 12, 10 }, { 38, 28, 300, 4380, 17, 14 }, { 45, 24, 250, 3600, 15, 12 },
}
for i, s in ipairs(samples) do
    sessions[i] = {
        id = "sample-" .. i, date = day(s[1]), book_title = "Sample", active_seconds = s[2] * 60,
        sentences = s[3], words = s[4], holds = s[5], backs = s[6],
    }
end
local util = require("util")
util.writeToFile(rapidjson.encode({ sessions = rapidjson.array(sessions) }), sp:statsPath(), true)
sp.stats_session = nil
sp:showStats(); paint()
shot("stats")
closePopups(ui)
print("done")
