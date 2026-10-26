--[[--
Spotlight's speed panel: a slider for the Auto mode speed (words per minute)
with − and + buttons, modelled on KOReader's frontlight panel
(frontend/ui/widget/frontlightwidget.lua): a title bar, a "− value +" row, and
a ProgressWidget you tap or drag along to set the value. Tapping outside the
panel closes it. Changes apply at once, through `on_change`.

    SpeedPanel:new{ value = 200, min = 80, max = 400, step = 5, on_change = function(wpm) end }

@module spotlight.speedpanel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
-- `_` is KOReader's translation function: never use it as a loop variable.
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local SpeedPanel = InputContainer:extend{
    name = "SpotlightSpeedPanel",
    value = 200,
    min = 80,
    max = 400,
    step = 5,
    on_change = nil,
}

function SpeedPanel:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.width = math.floor(sw * 0.95)
    self.inner_width = self.width - 2 * Size.padding.large
    self.button_width = math.floor(self.inner_width / 4)
    self.span = math.floor(sh * 0.01)
    self.face = Font:getFace("ffont")

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local whole = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self.ges_events = {
            TapSlider = { GestureRange:new{ ges = "tap", range = whole } },
            PanSlider = { GestureRange:new{ ges = "pan", range = whole } },
        }
    end
    self:layout()
end

function SpeedPanel:layout()
    self.minus = Button:new{
        text = "−",
        width = self.button_width,
        show_parent = self,
        callback = function() self:setValue(self.value - self.step) end,
    }
    self.plus = Button:new{
        text = "＋",
        width = self.button_width,
        show_parent = self,
        callback = function() self:setValue(self.value + self.step) end,
    }
    self.label = TextWidget:new{
        text = T(_("%1 wpm"), self.value),
        face = self.face,
        max_width = self.inner_width - 2 * self.button_width,
    }
    local label_box = CenterContainer:new{
        dimen = Geom:new{ w = self.label.max_width, h = self.label:getSize().h },
        self.label,
    }
    self.slider = ProgressWidget:new{
        width = self.inner_width,
        height = Size.item.height_big,
        percentage = self:percentage(),
        ticks = nil,
        last = nil,
    }
    local ends = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = T(_("%1 wpm"), self.min), face = Font:getFace("ffont", 16) },
        HorizontalSpan:new{ width = self.inner_width - 2 * Screen:scaleBySize(90) },
        TextWidget:new{ text = T(_("%1 wpm"), self.max), face = Font:getFace("ffont", 16) },
    }
    local gap = VerticalSpan:new{ width = math.floor(self.span * 1.5) }
    local body = VerticalGroup:new{
        align = "center",
        gap,
        HorizontalGroup:new{ align = "center", self.minus, label_box, self.plus },
        gap,
        self.slider,
        VerticalSpan:new{ width = self.span },
        ends,
        gap,
    }
    local title_bar = TitleBar:new{
        title = _("Spotlight speed"),
        width = self.width,
        align = "left",
        with_bottom_line = true,
        bottom_v_padding = 0,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_bar,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = body:getSize().h },
                body,
            },
        },
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
        self.frame,
    }
    self:updateButtons()
end

function SpeedPanel:percentage()
    return (self.value - self.min) / (self.max - self.min)
end

function SpeedPanel:updateButtons()
    if self.value <= self.min then self.minus:disable() else self.minus:enable() end
    if self.value >= self.max then self.plus:disable() else self.plus:enable() end
end

--- snap: round to the step (the slider). The − and + buttons move exactly one
-- step from wherever the speed is (auto-adjust can leave it at e.g. 181).
function SpeedPanel:setValue(v, snap)
    if snap then
        v = math.floor(v / self.step + 0.5) * self.step
    else
        v = math.floor(v + 0.5)
    end
    v = math.max(self.min, math.min(self.max, v))
    if v == self.value then return end
    self.value = v
    self.label:setText(T(_("%1 wpm"), v))
    self.slider:setPercentage(self:percentage())
    self:updateButtons()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    if self.on_change then self.on_change(v) end
end

--- Tap or drag on the slider sets the speed; a tap outside the panel closes it.
function SpeedPanel:onTapSlider(_arg, ges)
    if not self.slider.dimen or not self.frame.dimen then return true end
    if ges.pos:intersectWith(self.slider.dimen) then
        local perc = self.slider:getPercentageFromPosition(ges.pos)
        if perc then
            self:setValue(self.min + perc * (self.max - self.min), true)
        end
    elseif ges.ges == "tap" and not ges.pos:intersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end
SpeedPanel.onPanSlider = SpeedPanel.onTapSlider

function SpeedPanel:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

function SpeedPanel:onCloseWidget()
    UIManager:setDirty(nil, function() return "flashui", self.frame.dimen end)
end

function SpeedPanel:onClose()
    UIManager:close(self)
    return true
end

return SpeedPanel
