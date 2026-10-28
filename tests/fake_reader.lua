--[[
A stand-in for KOReader, just enough to load spotlight.koplugin/main.lua on a
desktop and drive it with a fake crengine document.

FakeDoc copies crengine's word-walking rules (crengine/src/lvtinydom.cpp:
ldomXPointerEx::nextVisibleWordEnd, prevVisibleWordEnd, prevVisibleWordStart,
nextVisibleChar, prevVisibleChar) and the "\n" that getTextFromXPointers puts
between blocks (ldomXRange::getRangeText). Each paragraph is one text node,
with xpointers like "/body/p[3]/text().42".
]]

local Sentences = require("sentences")

local M = {}

-- KOReader module stubs ---------------------------------------------------

M.dirty = {}   -- every UIManager:setDirty call: { mode, region }
M.shown = {}   -- every UIManager:show call

local Geom = {}
Geom.__index = Geom
function Geom:new(o) return setmetatable(o or {}, Geom) end
function Geom.boundingBox(boxes)
    local x0, y0, x1, y1
    for _, b in ipairs(boxes) do
        x0 = x0 and math.min(x0, b.x) or b.x
        y0 = y0 and math.min(y0, b.y) or b.y
        x1 = x1 and math.max(x1, b.x + b.w) or b.x + b.w
        y1 = y1 and math.max(y1, b.y + b.h) or b.y + b.h
    end
    if not x0 then return nil end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
function Geom:combine(b) return Geom.boundingBox({ self, b }) end

-- A clock the tests move by hand (milliseconds), and UIManager's timers on it.
M.clock_ms = 0
M.tasks = {}          -- { due_ms, fn }
M.top_widget = nil    -- what UIManager:getTopmostVisibleWidget returns (nil: the reader)
M.plugin_share = {}
M.is_kindle = false
M.powerd = { t1_resets = 0, resetT1Timeout = function(self) self.t1_resets = self.t1_resets + 1 end }

--- Move the clock forward, running every timer that comes due on the way.
function M.advance(ms)
    local target = M.clock_ms + ms
    while true do
        local next_task, idx
        for i, t in ipairs(M.tasks) do
            if t.due <= target and (not next_task or t.due < next_task.due) then next_task, idx = t, i end
        end
        if not next_task then break end
        table.remove(M.tasks, idx)
        M.clock_ms = math.max(M.clock_ms, next_task.due)
        next_task.fn()
    end
    M.clock_ms = target
end

function M.pendingTasks() return #M.tasks end

M.store_files = {} -- LuaSettings files by path: { data, flushed }
M.files = {}       -- plain files written through util.writeToFile, by path
M.dirs = {}

local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path)
    local f = M.store_files[path]
    if not f then
        f = { data = {}, flushes = 0 }
        M.store_files[path] = f
    end
    return setmetatable({ file = f, data = f.data }, LuaSettings)
end
function LuaSettings:readSetting(k, default)
    if self.data[k] == nil and default ~= nil then self.data[k] = default end
    return self.data[k]
end
function LuaSettings:saveSetting(k, v) self.data[k] = v end
function LuaSettings:flush() self.file.flushes = self.file.flushes + 1 end

M.menu_order = {
    navi = { "table_of_contents", "bookmarks", "----------------------------", "go_to", "autoturn" },
}

local stubs = {
    ["ffi/blitbuffer"] = { COLOR_BLACK = "black" },
    ["device"] = {
        screen = {
            scaleBySize = function(_, v) return v end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
        isTouchDevice = function() return true end,
        isKindle = function() return M.is_kindle == true end,
        getPowerDevice = function() return M.powerd end,
    },
    ["pluginshare"] = M.plugin_share,
    ["ui/widget/textwidget"] = {
        new = function(_, o)
            o.getSize = function() return { w = 10 * #o.text, h = 20 } end
            o.paintTo = function(self, bb, x, y)
                if bb.ops then bb.ops[#bb.ops + 1] = { "text", x, y, self.text } end
            end
            o.free = function() end
            return o
        end,
    },
    ["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end },
    ["ui/widget/confirmbox"] = { new = function(_, t) t.confirm = true; return t end },
    ["ui/bidi"] = { mirroredUILayout = function() return M.mirrored_ui == true end },
    ["ui/widget/keyvaluepage"] = { new = function(_, t) t.kv = true; return t end },
    ["rapidjson"] = require("json_lite"),
    ["util"] = {
        readFromFile = function(path) return M.files[path] end,
        writeToFile = function(data, path)
            if M.unwritable and path:find(M.unwritable, 1, true) then return nil, "read-only" end
            M.files[path] = data
            return true
        end,
        makePath = function(path) M.dirs[path] = true return true end,
    },
    ["apps/filemanager/filemanagerutil"] = { getHomeFolder = function() return "/fake/home" end },
    ["datastorage"] = { getSettingsDir = function() return "/fake/settings" end },
    ["luasettings"] = LuaSettings,
    ["ui/event"] = { new = function(_, name, ...) return { name = name, args = { ... } } end },
    ["dispatcher"] = { registerAction = function() end },
    ["ui/geometry"] = Geom,
    ["ui/widget/infomessage"] = { new = function(_, t) return t end },
    ["ui/uimanager"] = {
        setDirty = function(_, widget, refresh)
            local mode, region = refresh()
            M.dirty[#M.dirty + 1] = { widget = widget, mode = mode, region = region }
        end,
        show = function(_, w) M.shown[#M.shown + 1] = w end,
        scheduleIn = function(_, sec, fn)
            M.tasks[#M.tasks + 1] = { due = M.clock_ms + math.floor(sec * 1000 + 0.5), fn = fn }
        end,
        unschedule = function(_, fn)
            for i = #M.tasks, 1, -1 do
                if M.tasks[i].fn == fn then table.remove(M.tasks, i) end
            end
        end,
        getTopmostVisibleWidget = function() return M.top_widget or M.reader_ui end,
        nextTick = function(_, fn) M.tasks[#M.tasks + 1] = { due = M.clock_ms, fn = fn } end,
    },
    ["ui/widget/container/widgetcontainer"] = {
        extend = function(_, t) t.__index = t; return t end,
    },
    ["logger"] = {
        info = function(...) if os.getenv("SPOTLIGHT_LOG") then print(...) end end,
        dbg = function() end, warn = print, err = print,
    },
    ["ui/time"] = {
        now = function() return M.clock_ms * 1000 end,
        since = function(t) return M.clock_ms * 1000 - t end,
        to_ms = function(t) return math.floor(t / 1000) end,
    },
    ["gettext"] = function(s) return s end,
    -- KOReader's menu order table (a cached module, shared by everyone).
    ["ui/elements/reader_menu_order"] = M.menu_order,
    ["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

local settings_store = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return settings_store[k] end,
    saveSetting = function(_, k, v) settings_store[k] = v end,
}
function M.resetSettings()
    for k in pairs(settings_store) do settings_store[k] = nil end
    M.store_files = {}
    M.files = {}
    M.dirs = {}
    M.unwritable = nil
    M.mirrored_ui = false
    M.tasks = {}
    M.top_widget = nil
    M.clock_ms = 0
    for k in pairs(M.plugin_share) do M.plugin_share[k] = nil end
    M.is_kindle = false
    M.powerd.t1_resets = 0
end

--- Pretend the pace was learned already (Spotlight's own settings file).
function M.seedLearned(wpm, pause_ms)
    M.store_files["/fake/settings/spotlight.lua"] = {
        data = { learned = true, model = { wpm = wpm or 200, pause_ms = pause_ms or 400, n = 60 } },
        flushes = 0,
    }
end

--- The last popup shown, if it was a confirmation (ConfirmBox).
function M.lastConfirm()
    local w = M.shown[#M.shown]
    return w and w.confirm and w or nil
end

-- KOReader's tap zone defaults (defaults.lua).
_G.G_defaults = {
    values = {
        DTAP_ZONE_MENU = { x = 0, y = 0, w = 1, h = 1/8 },
        DTAP_ZONE_MENU_EXT = { x = 1/4, y = 0, w = 2/4, h = 1/5 },
        DTAP_ZONE_CONFIG = { x = 0, y = 7/8, w = 1, h = 1/8 },
        DTAP_ZONE_CONFIG_EXT = { x = 1/4, y = 4/5, w = 2/4, h = 1/5 },
    },
    readSetting = function(self, k) return self.values[k] end,
}

-- FakeDoc ------------------------------------------------------------------

local FakeDoc = {}
FakeDoc.__index = FakeDoc

local wc = Sentences.isWordChar

--- paragraphs: list of strings. pages: list of { para, word } page starts
--- (the page starts at the start of that word of that paragraph).
function M.newDoc(paragraphs, pages)
    local doc = setmetatable({ paras = {}, page_starts = {}, cur = 1, calls = 0 }, FakeDoc)
    for i, p in ipairs(paragraphs) do doc.paras[i] = Sentences.utf8Chars(p) end
    for i, ps in ipairs(pages) do
        local chars = doc.paras[ps[1]]
        local off, n = 0, 0
        for k = 1, #chars do
            if wc(chars[k]) and not wc(chars[k - 1]) then
                n = n + 1
                if n == ps[2] then off = k - 1; break end
            end
        end
        doc.page_starts[i] = { ps[1], off }
    end
    return doc
end

local function xp(p, off) return string.format("/body/p[%d]/text().%d", p, off) end
local function parse(s)
    local p, off = s:match("^/body/p%[(%d+)%]/text%(%)%.(%d+)$")
    return tonumber(p), tonumber(off)
end
M.parse = parse

function FakeDoc:getPageCount() return #self.page_starts end
function FakeDoc:getCurrentPage() return self.cur end
function FakeDoc:getPageXPointer(page)
    local ps = self.page_starts[page]
    if not ps then return "" end
    return xp(ps[1], ps[2])
end
function FakeDoc:getVisiblePageCount() return 1 end
function FakeDoc:getVisiblePageNumberCount() return 1 end
function FakeDoc:getPageMargins() return { left = 20, right = 20, top = 10, bottom = 10 } end

function FakeDoc:compareXPointers(a, b)
    local pa, oa = parse(a)
    local pb, ob = parse(b)
    if pa == pb and oa == ob then return 0 end
    if pb > pa or (pb == pa and ob > oa) then return 1 end
    return -1
end

function FakeDoc:getNextVisibleWordEnd(s)
    self.calls = self.calls + 1
    local p, off = parse(s)
    local moved = false
    while true do
        local chars = self.paras[p]
        if not chars then return nil end
        if off >= #chars then
            p, off, moved = p + 1, 0, true
            if not self.paras[p] then return nil end
            chars = self.paras[p]
        end
        while off <= #chars do
            if moved and off > 0 and wc(chars[off]) and (off == #chars or not wc(chars[off + 1])) then
                return xp(p, off)
            end
            off, moved = off + 1, true
        end
        p, off = p + 1, 0
    end
end

function FakeDoc:getPrevVisibleWordEnd(s)
    self.calls = self.calls + 1
    local p, off = parse(s)
    local moved = false
    while true do
        if off == 0 then
            p = p - 1
            if not self.paras[p] then return nil end
            off, moved = #self.paras[p], true
        end
        local chars = self.paras[p]
        while off > 0 do
            if moved and wc(chars[off]) and not wc(chars[off + 1]) then
                return xp(p, off)
            end
            off, moved = off - 1, true
        end
    end
end

function FakeDoc:getPrevVisibleWordStart(s)
    self.calls = self.calls + 1
    local p, off = parse(s)
    local moved = false
    while true do
        if off == 0 then
            p = p - 1
            if not self.paras[p] then return nil end
            off, moved = #self.paras[p], true
        end
        local chars = self.paras[p]
        while off >= 0 do
            if moved and wc(chars[off + 1]) and (off == 0 or not wc(chars[off])) then
                return xp(p, off)
            end
            if off == 0 then break end
            off, moved = off - 1, true
        end
    end
end

function FakeDoc:getNextVisibleChar(s)
    local p, off = parse(s)
    if off >= #self.paras[p] then
        if not self.paras[p + 1] then return nil end
        return xp(p + 1, 0)
    end
    return xp(p, off + 1)
end

function FakeDoc:getPrevVisibleChar(s)
    local p, off = parse(s)
    if off == 0 then
        if not self.paras[p - 1] then return nil end
        p, off = p - 1, #self.paras[p - 1]
    end
    return xp(p, off - 1)
end

function FakeDoc:getTextFromXPointers(a, b)
    self.calls = self.calls + 1
    if self:compareXPointers(a, b) == -1 then a, b = b, a end
    local pa, oa = parse(a)
    local pb, ob = parse(b)
    local out = {}
    for p = pa, pb do
        local chars = self.paras[p]
        local from = (p == pa) and oa + 1 or 1
        local to = (p == pb) and ob or #chars
        if p > pa then out[#out + 1] = "\n" end
        out[#out + 1] = table.concat(chars, "", from, to)
    end
    return table.concat(out)
end

--- One 10 px tall box per paragraph line part that is on the current page.
function FakeDoc:getScreenBoxesFromPositions(a, b)
    local start = self.page_starts[self.cur]
    local stop = self.page_starts[self.cur + 1]
    local boxes = {}
    local pa, oa = parse(a)
    local pb, ob = parse(b)
    for p = pa, pb do
        local from = (p == pa) and oa or 0
        local to = (p == pb) and ob or #self.paras[p]
        -- clip to the page
        if p < start[1] or (p == start[1] and to <= start[2]) then from = nil end
        if from and p == start[1] and from < start[2] then from = start[2] end
        if from and stop then
            if p > stop[1] or (p == stop[1] and from >= stop[2]) then from = nil
            elseif p == stop[1] and to > stop[2] then to = stop[2] end
        end
        if from and to > from then
            boxes[#boxes + 1] = Geom:new{ x = 40 + from, y = p * 20, w = to - from, h = 10 }
        end
    end
    return boxes
end

-- Plugin instance ----------------------------------------------------------

local plugin_path = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../spotlight.koplugin/main.lua"

--- A key press object, like KOReader's Key: matches a sequence of key names.
function M.key(name)
    return {
        match = function(_, seq)
            for _, k in ipairs(seq) do
                if type(k) == "table" then
                    for _, v in ipairs(k) do if v == name then return true end end
                elseif k == name then
                    return true
                end
            end
            return false
        end,
    }
end

function M.newPlugin(doc, opts)
    opts = opts or {}
    M.dirty, M.shown = {}, {}
    local Spotlight = dofile(plugin_path)
    local registered = { zones = {} }
    local plugin
    local doc_settings = { data = opts.doc_settings or {} }
    function doc_settings:readSetting(k) return self.data[k] end
    function doc_settings:saveSetting(k, v) self.data[k] = v end
    function doc_settings:delSetting(k) self.data[k] = nil end
    local ui = {
        document = doc,
        doc_settings = doc_settings,
        rolling = {
            key_events = {
                GotoNextView = { { { "RPgFwd", "LPgFwd", "Right" } }, event = "GotoViewRel", args = 1 },
                GotoPrevView = { { { "RPgBack", "LPgBack", "Left" } }, event = "GotoViewRel", args = -1 },
            },
        },
        highlight = {},
        menu = { registerToMainMenu = function(_, w) registered.menu = w end },
        registerTouchZones = function(_, zones)
            for _, z in ipairs(zones) do registered.zones[z.id] = z end
        end,
        page_turns = {},
    }
    -- ReaderRolling turning a page, then the PageUpdate broadcast.
    function ui:handleEvent(ev)
        if ev.name == "GotoViewRel" then
            local new = doc.cur + ev.args[1]
            self.page_turns[#self.page_turns + 1] = ev.args[1]
            if new >= 1 and new <= doc:getPageCount() then
                doc.cur = new
                plugin:onPageUpdate(new)
            end
            return true
        end
    end
    if opts.no_rolling then ui.rolling = nil end
    M.reader_ui = ui
    local footer = { contents = {}, settings = { all_at_once = opts.footer_all_at_once or false } }
    function footer:addAdditionalFooterContent(f) self.contents[#self.contents + 1] = f end
    function footer:removeAdditionalFooterContent(f)
        for i, g in ipairs(self.contents) do if g == f then table.remove(self.contents, i) return end end
    end
    function footer:getHeight() return 30 end
    function footer:text()
        local out = {}
        for _i, f in ipairs(self.contents) do out[#out + 1] = f() end
        return table.concat(out, " | ")
    end
    local view = {
        footer = footer,
        footer_visible = true,
        view_mode = opts.view_mode or "page",
        dialog = "reader-dialog",
        registerViewModule = function(_, name, w) registered.view = name end,
    }
    if opts.break_setup then
        Spotlight = setmetatable({ openStore = function() error("boom") end }, { __index = Spotlight })
        Spotlight.__index = Spotlight
    end
    plugin = setmetatable({ ui = ui, view = view, registered = registered }, Spotlight)
    plugin:init()
    if not opts.no_ready then plugin:onReaderReady() end
    return plugin
end

--- A paint target that records what the plugin draws.
function M.newCanvas()
    local c = { ops = {} }
    function c:darkenRect(x, y, w, h, f) self.ops[#self.ops + 1] = { "darken", x, y, w, h, f } end
    function c:paintRect(x, y, w, h, color) self.ops[#self.ops + 1] = { "paint", x, y, w, h, color } end
    function c:invertRect(x, y, w, h) self.ops[#self.ops + 1] = { "invert", x, y, w, h } end
    return c
end

return M
