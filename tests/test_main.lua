-- main.lua driven by a fake crengine document (see fake_reader.lua).
local Fake = require("fake_reader")
local test, eq, ok = T.test, T.eq, T.ok

local PARAS = {
    "Chapter One",
    "It was a dark night. Mr. Smith walked home slowly. The rain kept falling on the old town, and he "
        .. "thought about “the letter.” Nothing. She was gone.",
    "“Go now,” she said. He left at once.",
}
-- Page 1: from "Chapter" to "he"; page 2 starts at "thought"; page 3 at "“Go".
local PAGES = { { 1, 1 }, { 2, 21 }, { 3, 1 } }

local function texts(entry)
    local out = {}
    for i, s in ipairs(entry.sentences) do out[i] = s.text end
    return out
end

local function newPlugin(opts)
    Fake.resetSettings()
    local doc = Fake.newDoc(PARAS, PAGES)
    local plugin = Fake.newPlugin(doc, opts)
    return plugin, doc
end

test("registers its menu and view module for reflowable books", function()
    local plugin = newPlugin()
    eq(plugin.registered.view, "spotlight")
    ok(plugin.registered.menu == plugin)
end)

test("does nothing for books without CREngine", function()
    local plugin = newPlugin({ no_rolling = true })
    eq(plugin.registered.view, nil)
    ok(not plugin:isActive())
    plugin:onSpotlightToggle()
    eq(#Fake.shown, 1) -- tells the user why
end)

test("page 1: sentences, including the one running onto page 2", function()
    local plugin = newPlugin()
    local entry = plugin:buildPage(1)
    eq(texts(entry), {
        "Chapter One",
        "It was a dark night.",
        "Mr. Smith walked home slowly.",
        "The rain kept falling on the old town, and he thought about “the letter.” Nothing.",
    })
    ok(entry.sentences[4].ends_after)
    ok(not entry.sentences[4].starts_before)
end)

test("page 2 starts with the rest of that sentence, under the same key", function()
    local plugin = newPlugin()
    local p1 = plugin:buildPage(1)
    local p2 = plugin:buildPage(2)
    eq(texts(p2), {
        "The rain kept falling on the old town, and he thought about “the letter.” Nothing.",
        "She was gone.",
    })
    ok(p2.sentences[1].starts_before)
    eq(p2.sentences[1].key, p1.sentences[4].key)
end)

test("page 3: opening quote is part of the sentence", function()
    local plugin = newPlugin()
    eq(texts(plugin:buildPage(3)), { "“Go now,” she said.", "He left at once." })
end)

test("sentence ranges cover exactly the sentence text, punctuation included", function()
    local plugin, doc = newPlugin()
    for page = 1, 3 do
        for _, s in ipairs(plugin:buildPage(page).sentences) do
            local pos0, pos1 = plugin:sentenceRange(s)
            eq(doc:getTextFromXPointers(pos0, pos1), s.text, "range of: " .. s.text)
        end
    end
end)

test("turning on lights the first sentence and refreshes only its area", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    ok(plugin:isActive())
    eq(plugin:currentSentence().text, "Chapter One")
    eq(#Fake.dirty, 1)
    eq(Fake.dirty[1].mode, "ui")
    local r = Fake.dirty[1].region
    ok(r and r.h <= 12, "region is one line tall")
end)

test("paints the band behind the text and the bar in the margin", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    eq(#canvas.ops, 2)
    eq(canvas.ops[1][1], "darken")
    eq(canvas.ops[1][6], 0.2)
    local bar = canvas.ops[2]
    eq(bar[1], "paint")
    eq(bar[4], 5)               -- 5 px wide
    eq(bar[2] + bar[4], 40 - 6) -- ends a 6 px gap before the text, which starts at x = 40
end)

test("bar-only and underline styles", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    plugin:setLook("style", "bar")
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    eq(#canvas.ops, 1)
    eq(canvas.ops[1][1], "paint")
    plugin:setLook("style", "underline")
    canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    eq(#canvas.ops, 1)
    eq(canvas.ops[1][5], 2) -- a 2 px line
end)

test("a page turn moves the light to the first sentence on the new page", function()
    local plugin, doc = newPlugin()
    plugin:setEnabled(true)
    doc.cur = 2
    plugin:onPageUpdate(2)
    local s = plugin:currentSentence()
    ok(s.starts_before)
    -- Only the part on page 2 is drawn.
    local g = plugin:geometry(s)
    eq(#g.bands, 1)
    -- Pages 1 to 3 cached, nothing older.
    doc.cur = 3
    plugin:onPageUpdate(3)
    eq(plugin:currentSentence().text, "“Go now,” she said.")
    ok(plugin.pages[1] == nil)
end)

test("draws nothing when off, or when the page shown is not the lit one", function()
    local plugin, doc = newPlugin()
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    eq(#canvas.ops, 0)
    plugin:setEnabled(true)
    doc.cur = 2 -- page changed without a PageUpdate yet
    plugin:paintTo(canvas, 0, 0)
    eq(#canvas.ops, 0)
end)

test("turning off clears the light and refreshes the old area", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    plugin:paintTo(Fake.newCanvas(), 0, 0)
    plugin:setEnabled(false)
    eq(plugin:currentSentence(), nil)
    eq(#Fake.dirty, 2)
    ok(Fake.dirty[2].region ~= nil)
end)

test("scroll mode: stays off and says why", function()
    local plugin = newPlugin({ view_mode = "scroll" })
    plugin:setEnabled(true)
    ok(not plugin:isActive())
    eq(#Fake.shown, 1)
end)

test("a layout change rebuilds the page", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    local before = plugin.pages[1]
    plugin:onDocumentRerendered()
    ok(plugin.pages[1] ~= before)
    eq(plugin:currentSentence().text, "Chapter One")
end)

test("the menu entry goes to the top of the first tab, once", function()
    newPlugin()
    newPlugin() -- a second book in the same KOReader run
    local navi = Fake.menu_order.navi
    eq(navi[1], "spotlight")
    eq(navi[2], "----------------------------")
    local count = 0
    for _, id in ipairs(navi) do if id == "spotlight" then count = count + 1 end end
    eq(count, 1)
end)

test("books Spotlight cannot handle still get a menu entry that says so", function()
    local plugin = newPlugin({ no_rolling = true })
    ok(plugin.registered.menu == plugin)
    local items = {}
    plugin:addToMainMenu(items)
    eq(items.spotlight.text, "Spotlight (not for this book)")
    items.spotlight.callback()
    eq(#Fake.shown, 1)
end)

test("a startup error is caught, logged and shown in the menu", function()
    Fake.resetSettings()
    local doc = Fake.newDoc(PARAS, PAGES)
    local plugin = Fake.newPlugin(doc, { no_ready = true, break_setup = true })
    ok(not plugin:isSupported())
    local items = {}
    plugin:addToMainMenu(items)
    eq(items.spotlight.text, "Spotlight (could not start)")
    ok(plugin.startup_error:find("boom"))
    -- Nothing else reacts.
    plugin:onReaderReady()
    plugin:onPageUpdate(1)
    plugin:paintTo(Fake.newCanvas(), 0, 0)
end)

-- Walk a menu the way KOReader's touch menu does: every text, check and
-- enable function, every submenu.
local function walkMenu(items, visit)
    for _i, item in ipairs(items) do
        visit(item)
        if item.text_func then item.text_func() end
        if item.checked_func then item.checked_func() end
        if item.enabled_func then item.enabled_func() end
        local sub = item.sub_item_table or (item.sub_item_table_func and item.sub_item_table_func())
        if sub then walkMenu(sub, visit) end
    end
end

test("the whole menu builds for a reflowable book", function()
    local plugin = newPlugin()
    local items = {}
    plugin:addToMainMenu(items)
    ok(items.spotlight, "menu entry exists")
    eq(items.spotlight.text, "Spotlight")
    local count = 0
    walkMenu({ items.spotlight }, function() count = count + 1 end)
    ok(count >= 12, "all look options are there")
end)

test("every menu callback runs", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    -- The speed panel is a real KOReader widget: checked in tests/koreader.
    local panel_opened = false
    plugin.showSpeedPanel = function() panel_opened = true end
    local items = {}
    plugin:addToMainMenu(items)
    walkMenu(items.spotlight.sub_item_table, function(item)
        if item.callback and not item.sub_item_table then item.callback() end
    end)
    ok(panel_opened, "Speed opens the speed panel")
end)

-- Night mode -----------------------------------------------------------------

local Screen = require("device").screen

local function ops(plugin)
    local canvas = Fake.newCanvas()
    plugin:paintTo(canvas, 0, 0)
    local kinds = {}
    for i, op in ipairs(canvas.ops) do kinds[i] = op[1] end
    return kinds, canvas.ops
end

test("night mode, Bright sentence (default): the band is inverted to day colours", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    eq(plugin.settings.night_look, "bright")
    Screen.night_mode = true
    local kinds = ops(plugin)
    Screen.night_mode = nil
    eq(kinds, { "invert", "paint" }) -- band inverted, bar painted
end)

test("night mode, Soft glow: the dim band as before", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    plugin:setLook("night_look", "glow")
    Screen.night_mode = true
    local kinds = ops(plugin)
    Screen.night_mode = nil
    eq(kinds, { "darken", "paint" })
end)

test("day mode ignores the night look", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    eq((ops(plugin)), { "darken", "paint" })
end)

test("the night look only changes the band style", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    plugin:setLook("style", "underline")
    Screen.night_mode = true
    local kinds = ops(plugin)
    Screen.night_mode = nil
    eq(kinds, { "paint" })
end)

test("overlapping lines get bands that do not overlap", function()
    local plugin, doc = newPlugin()
    plugin:setEnabled(true)
    doc.getScreenBoxesFromPositions = function()
        return {
            { x = 40, y = 100, w = 300, h = 40 },
            { x = 40, y = 136, w = 300, h = 40 }, -- 4 px into the line above
        }
    end
    local g = plugin:geometry({ first_e = "/body/p[2]/text().2", last_e = "/body/p[2]/text().7", lead = 0, trail = 0, pos0 = "a", pos1 = "b" })
    eq(g.bands[2].y, g.bands[1].y + g.bands[1].h)
    eq(g.bands[2].y + g.bands[2].h, 176) -- still reaches the bottom of its line
end)

test("the night look is in the Look menu", function()
    local plugin = newPlugin()
    local items = {}
    plugin:addToMainMenu(items)
    local look
    for _i, item in ipairs(items.spotlight.sub_item_table) do
        if item.text == "Look" then look = item.sub_item_table end
    end
    local night = look[#look]
    eq(night.text_func(), "In night mode: Bright sentence (day colours)")
    eq(#night.sub_item_table, 2)
    night.sub_item_table[2].callback()
    eq(night.text_func(), "In night mode: Soft glow (dim band)")
end)

test("the bar stays at the page's text edge, not the sentence's indent", function()
    local plugin = newPlugin()
    plugin:setEnabled(true)
    -- Sentence 3 starts mid-line ("Mr. Smith..."): its own boxes start well
    -- right of the text edge, but the bar does not move.
    local g1 = plugin:geometry(plugin.pages[1].sentences[1])
    local g3 = plugin:geometry(plugin.pages[1].sentences[3])
    ok(g3.bands[1].x > g1.bands[1].x)
    eq(g3.bars[1].x, g1.bars[1].x)
end)

test("pieces of one line side by side (a drop cap) are both lit, without overlapping", function()
    local plugin, doc = newPlugin()
    plugin:setEnabled(true)
    doc.getScreenBoxesFromPositions = function()
        return {
            { x = 68, y = 1480, w = 42, h = 64 },   -- the drop cap
            { x = 110, y = 1481, w = 1034, h = 63 }, -- the rest of the line
        }
    end
    local g = plugin:geometry({ first_e = "x", last_e = "y", lead = 0, trail = 0, pos0 = "a", pos1 = "b" })
    eq(#g.bands, 2)
    ok(g.bands[2].h == 63, "the rest of the line keeps its height")
    eq(g.bands[2].x, g.bands[1].x + g.bands[1].w)       -- starts where the drop cap's band ends
    eq(g.bands[2].x + g.bands[2].w, 110 + 1034 + 2)      -- and still reaches the end of the line
end)

test("_meta.lua and main.lua agree on the version", function()
    local dir = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../spotlight.koplugin/"
    local meta = dofile(dir .. "_meta.lua")
    local f = io.open(dir .. "main.lua")
    local src = f:read("*a")
    f:close()
    local version = src:match('local VERSION = "([^"]+)"')
    ok(meta.version and meta.version:match("^%d+%.%d+%.%d+$"), "meta version " .. tostring(meta.version))
    eq(meta.version, version)
end)
