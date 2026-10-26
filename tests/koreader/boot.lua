-- Headless KOReader, set up like KOReader's own spec/unit/commonrequire.lua.
-- Run from the KOReader folder:  KO_HOME=... ./luajit <this file> <book.epub>
require("setupkoenv")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
require("dbg"):turnOff()
local logger = require("logger")
logger:setLevel(logger.levels.info)

G_defaults = require("luadefaults"):open(DataStorage:getDataDir() .. "/defaults.custom.lua")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")

einkfb = require("ffi/framebuffer") -- luacheck: ignore
einkfb.dummy = true                 -- no SDL window
local Device = require("device")
local Screen = Device.screen
-- The dummy screen is hard-coded to 600 x 800; size it like a Paperwhite 5
-- (harness only, KOReader itself is not changed on disk).
do
    local BB = require("ffi/blitbuffer")
    local new = BB.new
    BB.new = function(w, h, ...)
        if w == 600 and h == 800 then w, h = 1236, 1648 end
        return new(w, h, ...)
    end
    Screen:init()
    BB.new = new
end
require("document/canvascontext"):init(Device)
Device.input.dummy = true

local H = {}
H.Device, H.Screen, H.DataStorage, H.logger = Device, Screen, DataStorage, logger
H.UIManager = require("ui/uimanager")
H.Event = require("ui/event")
H.Geom = require("ui/geometry")
H.time = require("ui/time")
H.Key = require("device/key")

function H.open(book)
    local ReaderUI = require("apps/reader/readerui")
    local DocumentRegistry = require("document/documentregistry")
    local ui = ReaderUI:new{ dimen = Screen:getSize(), document = DocumentRegistry:openDocument(book) }
    H.UIManager:show(ui)
    H.paint()
    return ui
end

function H.paint()
    H.UIManager:forceRePaint()
end

function H.shot(name)
    lfs.mkdir(DataStorage:getDataDir() .. "/shots")
    local path = DataStorage:getDataDir() .. "/shots/" .. name .. ".png"
    Screen:shot(path)
    return path
end

function H.gesture(ui, ges)
    ges.time = ges.time or H.time.now()
    if ges.pos and not getmetatable(ges.pos) then ges.pos = H.Geom:new(ges.pos) end
    return ui:handleEvent(H.Event:new("Gesture", ges))
end

function H.tap(ui, x, y)
    return H.gesture(ui, { ges = "tap", pos = { x = x, y = y, w = 0, h = 0 } })
end

function H.key(ui, name)
    return ui:handleEvent(H.Event:new("KeyPress", H.Key:new(name, {})))
end

return H
