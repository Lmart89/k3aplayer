--[[--
K3 Audio Player: side panel with the player options. Takes ⅔ of the width, below the top bar, over
the player. A window of its own: opening or closing it does not repaint the player behind it.

One table of buttons (one focus): the D-pad walks the options, Press picks one and Menu or Back
close it. Each option closes the panel before doing its thing.

    UIManager:show(Panel:new{ title = "…", options = { { text, action }, … }, top = bar height },
        nil, nil, 0, bar height)
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Input = Device.input
local Screen = Device.screen

local Panel = InputContainer:extend{
    name = "k3aplayer_panel",
    title = "",
    options = nil,
    top = 0, -- height of the top bar: the panel starts below it
}

function Panel:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local width = math.floor(screen_w * 2 / 3)
    local border = Size.border.window * 2
    local inner = width - border
    local pad = Size.padding.large
    local height = screen_h - self.top
    self.dimen = Geom:new{ x = 0, y = self.top, w = width, h = height }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back }, { "Menu" } }
    end
    local rows = {}
    for _, o in ipairs(self.options or {}) do
        local action = o[2]
        rows[#rows + 1] = { { text = o[1], align = "left", callback = function()
            UIManager:close(self)
            action()
        end } }
    end
    self.table = ButtonTable:new{ width = inner - 2 * pad, show_parent = self, buttons = rows }
    self[1] = FrameContainer:new{
        width = width, height = height,
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "top",
            FrameContainer:new{
                width = inner, height = height, padding = pad, bordersize = 0,
                VerticalGroup:new{
                    align = "left",
                    TextWidget:new{ text = self.title, face = Font:getFace("x_smallinfofont"),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = inner - 2 * pad },
                    VerticalSpan:new{ width = pad },
                    self.table,
                },
            },
            LineWidget:new{ dimen = Geom:new{ w = border, h = height } },
        },
    }
end

function Panel:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

--- On close, only its area is repainted and refreshed: the player behind did not change.
function Panel:onCloseWidget()
    local area = self.dimen
    UIManager:setDirty(nil, function() return "ui", area end)
end

function Panel:onClose()
    UIManager:close(self)
    return true
end

return Panel
