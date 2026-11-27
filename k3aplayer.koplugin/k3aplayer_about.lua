--[[--
K3 Audio Player: the About screen. App icon (icons/app.svg), name, version, a short description,
the author, the GitHub address with the GitHub mark (icons/github.svg), and a few facts about this
installation (music folder, songs, engine log). Back (or Menu) closes it.

    UIManager:show(require("k3aplayer_about"):new{})
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
-- English only: KOReader's gettext would translate just the words its own catalog knows
-- ("off", "About"…) and leave the rest in English, mixing two languages
local _ = function(s) return s end
local T = require("ffi/util").template
local Music = require("k3aplayer_music")
local Input = Device.input
local Screen = Device.screen

local About = InputContainer:extend{
    name = "k3aplayer_about",
    covers_fullscreen = true,
}

About.NAME = "K3 Audio Player"
About.VERSION = "1.0"
About.AUTHOR = "lmart89"
About.GITHUB = "github.com/Lmart89"

local ICON_DIR = ((debug.getinfo(1, "S").source or ""):match("^@(.*)[/\\]") or ".") .. "/icons/"

local function px(n) return Screen:scaleBySize(n) end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function About:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back }, { "Menu" } }
    end
    local width = math.floor(w * 0.85)
    local logo = px(130)
    local content = VerticalGroup:new{ align = "center" }
    local function add(widget) content[#content + 1] = widget end
    local function gap(n) add(VerticalSpan:new{ width = px(n) }) end

    if fileExists(ICON_DIR .. "app.svg") then
        add(IconWidget:new{ file = ICON_DIR .. "app.svg", width = logo, height = logo, alpha = true })
        gap(14)
    end
    add(TextWidget:new{ text = About.NAME, face = Font:getFace("tfont", 28), bold = true })
    gap(4)
    add(TextWidget:new{ text = T(_("Version %1"), About.VERSION), face = Font:getFace("cfont", 18) })
    gap(14)
    add(TextBoxWidget:new{
        text = _("Music player for the Kindle 3."),
        face = Font:getFace("cfont", 19), width = width, alignment = "center",
    })
    gap(6)
    add(TextBoxWidget:new{
        text = T(_("Made by %1"), About.AUTHOR),
        face = Font:getFace("cfont", 18), width = width, alignment = "center",
    })
    gap(12)
    -- the GitHub address, with the GitHub mark on its left (just the address without the icon)
    local face = Font:getFace("cfont", 17)
    local address = TextWidget:new{ text = About.GITHUB, face = face, bold = true, max_width = width }
    local line = address
    if fileExists(ICON_DIR .. "github.svg") then
        local side = address:getSize().h
        line = HorizontalGroup:new{
            align = "center",
            IconWidget:new{ file = ICON_DIR .. "github.svg", width = side, height = side, alpha = true },
            HorizontalSpan:new{ width = px(8) },
            address,
        }
    end
    self.github_line = line
    add(line)
    gap(26)

    local n = #Music.songs()
    local facts = {
        { _("Music folder"), Music.folder() },
        { _("Songs"), tostring(n) },
        { _("Engine log"), Music.logPath() },
    }
    for _k, f in ipairs(facts) do
        add(TextBoxWidget:new{
            text = f[1] .. ": " .. f[2],
            face = Font:getFace("x_smallinfofont"), width = width, alignment = "center",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
        gap(6)
    end

    local footer = FrameContainer:new{ bordersize = 0, padding = px(12),
        TextWidget:new{ text = _("Back: close"), face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY } }
    self[1] = FrameContainer:new{
        width = w, height = h, background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        OverlapGroup:new{
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, content },
            BottomContainer:new{ dimen = Geom:new{ w = w, h = h },
                CenterContainer:new{ dimen = Geom:new{ w = w, h = footer:getSize().h }, footer } },
        },
    }
end

function About:onShow()
    UIManager:setDirty(self, "flashui")
    return true
end

function About:onCloseWidget()
    UIManager:setDirty(nil, "flashui")
end

function About:onClose()
    UIManager:close(self)
    return true
end

return About
