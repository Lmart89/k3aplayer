--[[--
K3 Audio Player: the screens. The player and the song list of the music folder. Rounded buttons,
pills and soft cards, in grays that e-ink can tell apart. The music itself is in k3aplayer_music;
here it is only shown and requested.

    Player:new{}   now playing: track, progress, 5 buttons, "Up next"
    Songs:new{}    the song list with "All" and "Shuffle"

Player: ◀ ▶ move the focus between the buttons, ▲ ▼ go down to "Up next", Press activates,
the page keys change song, Menu opens the options and Back returns (the music keeps playing).
Songs: ▲ ▼ choose, Press plays, page keys turn the page, Back returns.

Painting on the Kindle 3 is done in Lua (no C blitter): a full repaint costs seconds, so the screens
only repaint the part that changes (a button, a row, the progress) and refresh just that area.
The buttons and the cover are SVG icons (icons/*.svg), rasterized once by NanoSVG (in C), flattened
onto their background in the screen's format and then painted by copying bytes. The screen itself
is kept in memory, so closing the options panel or a notice puts it back instantly.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local datetime = require("datetime")
local _ = require("gettext")
local T = require("ffi/util").template
local Mp3 = require("k3aplayer_mp3")
local Music = require("k3aplayer_music")
local Input = Device.input
local Screen = Device.screen
local ffi_ok, ffi = pcall(require, "ffi")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local FOCUS = Blitbuffer.COLOR_GRAY_B     -- focus gray
local PILL = Blitbuffer.COLOR_GRAY_D      -- pill background
local CARD = Blitbuffer.COLOR_GRAY_E      -- card background
local DIM = Blitbuffer.COLOR_GRAY_5       -- secondary text

-- symbols of KOReader's icon font (nerdfonts/symbols.ttf)
local I = {
    music = "\u{F001}", play = "\u{F04B}", pause = "\u{F04C}", stop = "\u{F04D}",
    prev = "\u{F048}", next = "\u{F051}", volume = "\u{F028}", clock = "\u{F017}",
    shuffle = "\u{F074}", ["repeat"] = "\u{F01E}", list = "\u{F03A}", go = "\u{F04E}", keys = "\u{F11C}",
    folder = "\u{F07B}", wifi = "\u{F1EB}",
}

local function px(n) return Screen:scaleBySize(n) end

local function text(t, size, o)
    o = o or {}
    return TextWidget:new{ text = t, face = Font:getFace("cfont", size), bold = o.bold,
        fgcolor = o.color or BLACK, max_width = o.max }
end

---------------------------------------------------------------- SVG icons
-- A circle or pill drawn with FrameContainer is painted pixel by pixel in Lua on the K3 (~0.5 s per
-- button); an SVG is rasterized by NanoSVG (in C) once, flattened onto its background in the
-- screen's format and kept here; every later paint copies its bytes row by row. If an SVG cannot be
-- used, the old drawing is used instead.

local ICON_DIR = ((debug.getinfo(1, "S").source or ""):match("^@(.*)[/\\]") or ".") .. "/icons/"
local flats = {} -- "name|w|h|bg|odd" → ready-to-copy buffer (false if it failed)

--- The icon flattened onto bg, in the screen's buffer type. odd: starts one pixel earlier (so a
-- 4-bit buffer can be copied in whole bytes when x is odd); the width is always even.
local function flat(name, w, h, bg, odd)
    local key = table.concat({ name, w, h, bg.a or 0, odd and 1 or 0 }, "|")
    local p = flats[key]
    if p ~= nil then return p or nil end
    flats[key] = false
    if not Screen.bb or not ffi_ok then return nil end
    local ok, svg = pcall(function()
        return require("ui/renderimage"):renderSVGImageFile(ICON_DIR .. name .. ".svg", w, h)
    end)
    if not ok or not svg then
        require("logger").warn("[K3APlayer] icon not rendered:", name, ok and "" or tostring(svg))
        return nil
    end
    local left = odd and 1 or 0
    local width = w + left
    width = width + width % 2
    local ok2, b = pcall(function()
        local b = Blitbuffer.new(width, h, Screen.bb:getType())
        b:fill(bg)
        b:alphablitFrom(svg, left, 0, 0, 0, w, h)
        return b
    end)
    pcall(function() svg:free() end)
    if not ok2 then return nil end
    flats[key] = b
    return b
end

local Icon = Widget:extend{ name = nil, w = 0, h = 0, bg = WHITE }

function Icon:getSize() return Geom:new{ w = self.w, h = self.h } end

function Icon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local t = bb:getType()
    local div = (t == Blitbuffer.TYPE_BB4 and 2) or (t == Blitbuffer.TYPE_BB8 and 1) or nil
    local odd = div == 2 and x % 2 == 1
    local p = flat(self.name, self.w, self.h, self.bg, odd)
    if not p then return end
    local x0 = odd and x - 1 or x
    if div and p:getType() == t and bb:getRotation() == 0 and bb:getInverse() == 0 and p:getInverse() == 0
        and x0 >= 0 and y >= 0 and y + p.h <= bb.h and (x0 + p.w) / div <= bb.stride then
        -- straight copy, row by row
        local nb = p.w / div
        local dst = ffi.cast("uint8_t *", bb.data) + y * bb.stride + x0 / div
        local src = ffi.cast("uint8_t *", p.data)
        for r = 0, p.h - 1 do ffi.copy(dst + r * bb.stride, src + r * p.stride, nb) end
    else
        bb:blitFrom(p, x0, y, 0, 0, p.w, p.h)
    end
end

--- A w×h SVG icon over bg, or fallback() (the plain drawing) if it cannot be used.
local function icon(name, w, h, bg, fallback)
    if Screen.bb and flat(name, w, h, bg or WHITE, false) then
        return Icon:new{ name = name, w = w, h = h, bg = bg or WHITE }
    end
    return fallback()
end

--- Pill: text on a rounded background (or with a border).
local function pill(t, o)
    o = o or {}
    return FrameContainer:new{
        background = o.bg or PILL, bordersize = o.border or 0, color = BLACK,
        radius = px(14), padding = 0,
        padding_left = px(12), padding_right = px(12), padding_top = px(3), padding_bottom = px(3),
        text(t, o.size or 15, { bold = true, color = o.color }),
    }
end

--- A "left … right" row of a fixed width.
local function ends(left, right, width)
    local h = math.max(left:getSize().h, right:getSize().h)
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = width, h = h }, left },
        RightContainer:new{ dimen = Geom:new{ w = width, h = h }, right },
    }
end

local function centered(w, width)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = w:getSize().h }, w }
end

--- Wraps a widget in a borderless frame, so it can be repainted alone (repaintPart).
local function frame(w)
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, w }
end

--- List of choices with ✓ on the current one (one per row).
local function choose(title, choices)
    local dialog
    local rows = {}
    for _k, o in ipairs(choices) do
        rows[#rows + 1] = { { text = (o.current and "✓ " or "") .. o.text, callback = function()
            UIManager:close(dialog)
            o.on_tap()
        end } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = rows }
    UIManager:show(dialog)
end

local REPEAT_TEXT = { all = _("all"), one = _("one song"), off = _("off") }

local M = {} -- what the module exports (below: Player, Songs, menu, open)

---------------------------------------------------------------- base of both screens

local Screen_ = InputContainer:extend{
    covers_fullscreen = true,
    title = _("Music"),
}

function Screen_:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.Menu = { { "Menu" } }
        self.key_events.PageNext = { { Input.group.PgFwd } }
        self.key_events.PagePrev = { { Input.group.PgBack } }
        self.key_events.Up = { { "Up" } }
        self.key_events.Down = { { "Down" } }
        self.key_events.Left = { { "Left" } }
        self.key_events.Right = { { "Right" } }
        self.key_events.Activate = { { "Press" } }
    end
    self.listener = function(change) if not self.closed then self:onMusicChange(change) end end
    Music.listen(self.listener)
    self:build()
end

--- Time, Wi-Fi and battery: { time = "10:42", wifi = true if connected, battery = " 85%" or nil }.
local function deviceStatus()
    local e = { time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) }
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    e.wifi = ok and NetworkMgr and NetworkMgr:isConnected() and true or false
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        local level = powerd:getCapacity()
        local symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), level) or ""
        e.battery = string.format("%s %d%%", symbol, level)
    end
    return e
end

--- The music badge (♪ ▶ or ♪ ‖ in a black pill), the time, Wi-Fi (black if connected, gray if not)
-- and battery, in that order.
function Screen_:statusGroup()
    local e = deviceStatus()
    local face = Font:getFace("smallinfofont")
    local gap = HorizontalSpan:new{ width = 2 * Size.padding.default }
    local group = HorizontalGroup:new{ align = "center" }
    local badge = Music.badge()
    if badge then
        group[#group + 1] = FrameContainer:new{
            background = BLACK, bordersize = 0, radius = px(10),
            padding = 0, padding_left = Size.padding.default, padding_right = Size.padding.default,
            TextWidget:new{ text = badge, face = face, bold = true, fgcolor = WHITE },
        }
        group[#group + 1] = gap
    end
    group[#group + 1] = TextWidget:new{ text = e.time, face = face, bold = true }
    group[#group + 1] = gap
    group[#group + 1] = TextWidget:new{ text = I.wifi, face = face, bold = true,
        fgcolor = e.wifi and BLACK or Blitbuffer.COLOR_GRAY }
    if e.battery then
        group[#group + 1] = gap
        group[#group + 1] = TextWidget:new{ text = e.battery, face = face, bold = true }
    end
    self.status_text = (badge or "") .. "|" .. e.time .. "|" .. tostring(e.wifi) .. "|" .. (e.battery or "")
    return group
end

--- Top bar: the menu icon (Menu key), the title in a box, and the time, Wi-Fi and battery.
-- A thick line below.
function Screen_:topBar(screen_w)
    local pad = Size.padding.large
    local size = px(32)
    local menu = IconWidget:new{ icon = "appbar.menu", width = size, height = size }
    local group = self:statusGroup()
    -- room for the music badge even when nothing plays: when it appears it does not cover the title
    local reserve = 0
    if self.status_text:sub(1, 1) == "|" then
        local w = FrameContainer:new{ bordersize = 0, padding = 0,
            padding_left = Size.padding.default, padding_right = Size.padding.default,
            TextWidget:new{ text = "\u{F001} \u{F04B}", face = Font:getFace("smallinfofont"), bold = true } }
        reserve = w:getSize().w + 2 * Size.padding.default
    end
    self.status_widget = RightContainer:new{
        dimen = Geom:new{ w = group:getSize().w + reserve + px(24), h = group:getSize().h },
        group,
    }
    local free = screen_w - 4 * pad - size - self.status_widget:getSize().w
    local inner = free - 2 * Size.padding.default - 2 * Size.border.button
    local title = TextWidget:new{ text = self.title or "", face = Font:getFace("cfont", 20), bold = true,
        max_width = inner }
    local box = FrameContainer:new{
        bordersize = Size.border.button, radius = Size.radius.button,
        padding = Size.padding.default, padding_top = Size.padding.small, padding_bottom = Size.padding.small,
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = title:getSize().h }, title },
    }
    local height = math.max(box:getSize().h, size) + 2 * Size.padding.default
    -- where the time corner is (the bar is at the very top): to paint only there
    local d = self.status_widget.dimen
    self.status_area = Geom:new{ x = screen_w - pad - d.w, y = math.floor((height - d.h) / 2),
        w = d.w, h = d.h }
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            menu,
            HorizontalSpan:new{ width = pad },
            CenterContainer:new{ dimen = Geom:new{ w = free, h = height }, box },
            HorizontalSpan:new{ width = pad },
            self.status_widget,
            HorizontalSpan:new{ width = pad },
        },
        LineWidget:new{ dimen = Geom:new{ w = screen_w, h = Size.line.thick * 2 } },
    }
end

--- Redoes the time, Wi-Fi and battery if they changed and this screen is on top; refreshes only
-- that corner.
function Screen_:updateStatus()
    if self.closed or not self.status_widget or UIManager:getNthTopWidget() ~= self then return end
    local before = self.status_text
    local group = self:statusGroup()
    if self.status_text == before then return end
    self.status_widget[1] = group
    local z = self.status_area
    if z and Screen.bb then
        Screen.bb:paintRect(z.x, z.y, z.w, z.h, WHITE)
        self.status_widget:paintTo(Screen.bb, z.x, z.y)
        UIManager:setDirty(nil, function() return "ui", Geom:new{ x = z.x, y = z.y, w = z.w, h = z.h } end)
        if self.copy_ok then self:saveCopy() end
        return
    end
    local d = self.status_widget.dimen
    local width = d.w + 2 * Size.padding.large
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = Screen:getWidth() - width, y = d.y or 0, w = width, h = d.h }
    end)
end

--- Every minute: the time, Wi-Fi and battery.
function Screen_:scheduleStatus()
    self.clock = self.clock or function()
        if self.closed then return end
        self:updateStatus()
        UIManager:scheduleIn(60, self.clock)
    end
    UIManager:unschedule(self.clock)
    UIManager:scheduleIn(60, self.clock)
end

function Screen_:onNetworkConnected() self:updateStatus() end
function Screen_:onNetworkDisconnected() self:updateStatus() end

--- The whole screen: bar, content at the top and a help line at the bottom.
function Screen_:assemble(content, footer)
    local w, h = Screen:getWidth(), Screen:getHeight()
    local bar = self:topBar(w)
    self.bar_height = bar:getSize().h
    self[1] = FrameContainer:new{
        width = w, height = h, background = WHITE, bordersize = 0, padding = 0, margin = 0,
        OverlapGroup:new{
            dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new{ align = "center", bar, content },
            BottomContainer:new{ dimen = Geom:new{ w = w, h = h }, footer },
        },
    }
end

function Screen_:redraw()
    self.copy_ok = false
    self:build()
    UIManager:setDirty(self, "ui")
end

--- Copy of the painted screen. When something on top closes (the options panel, a notice, the
-- sleep screen) KOReader repaints the whole screen (~2.5 s on the K3); if nothing changed meanwhile,
-- putting this copy back is enough (a 240 KB memcpy). Any content change while covered, or a
-- redraw, invalidates it (copy_ok = false).
function Screen_:saveCopy()
    local bb = Screen.bb
    if not bb or not ffi_ok then return end
    local size = bb.stride * bb.h
    if not self.copy or self.copy_size ~= size then
        if self.copy then pcall(function() self.copy:free() end) end
        local ok, c = pcall(bb.copy, bb)
        self.copy, self.copy_size = ok and c or nil, size
    else
        ffi.copy(self.copy.data, bb.data, size)
    end
    self.copy_ok = self.copy ~= nil
end

function Screen_:dropCopy()
    if self.copy then pcall(function() self.copy:free() end) end
    self.copy, self.copy_ok = nil, false
end

--- Repaints only one frame (progress, a button, a row) with new content. If something is on top (a
-- notice, a menu), only the content changes: it shows when the screen is repainted.
-- bg: the color behind the frame (white, or a card's gray).
-- Returns true if it painted it (or if that was not needed because something is on top).
function Screen_:repaintPart(fr, new, bg)
    if new then fr[1] = new end
    if self.closed or UIManager:getNthTopWidget() ~= self then
        self.copy_ok = false -- it has to be really painted when we come back
        return true
    end
    local d = fr.dimen
    if not d or not d.x then return false end
    local area = Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    if not Screen.bb then -- no screen buffer (tests): the whole screen, refreshing the area
        UIManager:setDirty(self, function() return "ui", area end)
        return true
    end
    Screen.bb:paintRect(area.x, area.y, area.w, area.h, bg or WHITE)
    fr:paintTo(Screen.bb, area.x, area.y)
    UIManager:setDirty(nil, function() return "ui", area end)
    if self.copy_ok then self:saveCopy() end
    return true
end

function Screen_:paintTo(bb, x, y)
    local full = Screen.bb ~= nil and bb == Screen.bb and x == 0 and y == 0
    if full and self.copy_ok and self.copy and self.copy_size == bb.stride * bb.h then
        ffi.copy(bb.data, self.copy.data, self.copy_size)
        -- the time and battery in the copy may be old: the bar catches up right away
        UIManager:nextTick(function()
            if not self.closed and UIManager:getNthTopWidget() == self then
                self.status_text = nil
                self:updateStatus()
                self:saveCopy()
            end
        end)
        return
    end
    InputContainer.paintTo(self, bb, x, y)
    if full then self:saveCopy() end
end

function Screen_:onClose()
    UIManager:close(self)
    return true
end

function Screen_:onShow()
    UIManager:setDirty(self, "flashui")
    self:scheduleStatus()
    return true
end

function Screen_:onCloseWidget()
    self.closed = true
    self:dropCopy()
    Music.forget(self.listener)
    if self.clock then UIManager:unschedule(self.clock) end
    UIManager:setDirty(nil, "flashui")
end

---------------------------------------------------------------- player

local Player = Screen_:extend{
    name = "k3aplayer_player",
    title = _("Music"),
}

local BUTTONS = { "prev", "minus", "play", "plus", "next" }

function Player:build()
    self.focus = self.focus or { zone = "buttons", i = 3 }
    local w = Screen:getWidth()
    -- header (cover and title) and "Up next", each in its frame: on a song change only they repaint
    self.header_frame = frame(self:header())

    self.progress_frame = FrameContainer:new{
        bordersize = 0, padding = 0, width = w, height = px(56),
        self:progressGroup(),
    }

    local row = self:buttonRow()
    self.buttons_frame = FrameContainer:new{
        bordersize = 0, padding = 0, width = w, height = row:getSize().h,
        row,
    }

    -- status pills; the volume one has a fixed width and its own frame (it changes with the keys)
    self.volume_frame = FrameContainer:new{ bordersize = 0, padding = 0, self:volumePill() }
    local chips = { self.volume_frame,
        pill(T(_("Repeat: %1"), REPEAT_TEXT[Music.repeatMode()])),
        pill(T(_("Shuffle: %1"), Music.shuffle() and _("on") or _("off"))) }
    local left = Music.sleepLeft()
    if left then chips[#chips + 1] = pill(T(_("Stops in %1 min"), left), { bg = WHITE, border = px(2) }) end
    local chip_rows = VerticalGroup:new{ align = "center" }
    local chip_row = HorizontalGroup:new{ align = "center" }
    local row_w = 0
    for _k, ch in ipairs(chips) do
        local cw = ch:getSize().w
        if row_w > 0 and row_w + px(10) + cw > w - 2 * px(24) then
            chip_rows[#chip_rows + 1] = chip_row
            chip_rows[#chip_rows + 1] = VerticalSpan:new{ width = px(8) }
            chip_row, row_w = HorizontalGroup:new{ align = "center" }, 0
        end
        if row_w > 0 then chip_row[#chip_row + 1] = HorizontalSpan:new{ width = px(10) } end
        chip_row[#chip_row + 1] = ch
        row_w = row_w + (row_w > 0 and px(10) or 0) + cw
    end
    chip_rows[#chip_rows + 1] = chip_row

    self.card_frame = frame(self:card())

    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = px(22) },
        self.header_frame,
        VerticalSpan:new{ width = px(20) },
        self.progress_frame,
        VerticalSpan:new{ width = px(14) },
        self.buttons_frame,
        VerticalSpan:new{ width = px(22) },
        centered(chip_rows, w),
        VerticalSpan:new{ width = px(20) },
        self.card_frame,
    }
    local footer = FrameContainer:new{ bordersize = 0, padding = px(10),
        centered(text(_("◀ ▶ choose · Press activate · Menu options · Back: music keeps playing"), 13,
            { color = DIM }), w - px(20)) }
    self:assemble(content, footer)
end

--- Cover and song title, full width (always the same height).
function Player:header()
    local w = Screen:getWidth()
    local margin = px(32)
    local c, index = Music.current()
    local list = Music.songs()
    local cover = icon("cover", px(150), px(150), WHITE, function()
        return FrameContainer:new{
            background = CARD, bordersize = 0, radius = px(28), padding = 0,
            CenterContainer:new{ dimen = Geom:new{ w = px(150), h = px(150) },
                text(I.music, 64, { color = Blitbuffer.COLOR_GRAY_3 }) },
        }
    end)
    local title_w = w - 2 * margin - px(150) - px(22)
    local info = VerticalGroup:new{
        align = "left",
        text(_("NOW PLAYING"), 14, { bold = true, color = DIM }),
        VerticalSpan:new{ width = px(6) },
        text(c and c.title or _("Nothing playing"), 26, { bold = true, max = title_w }),
        VerticalSpan:new{ width = px(6) },
        text(c and c.name or _("Pick a song in Menu → Song list"), 15, { color = DIM, max = title_w }),
        VerticalSpan:new{ width = px(10) },
        pill(c and T(_("Song %1 of %2"), index, #list) or T(_("%1 songs"), #list)),
    }
    local header = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = margin }, cover, HorizontalSpan:new{ width = px(22) }, info,
    }
    return LeftContainer:new{ dimen = Geom:new{ w = w, h = header:getSize().h }, header }
end

--- One "Up next" row (n = 1…3), gray if it has the focus.
function Player:nextRow(n)
    local p = self.up_next[n]
    local inner = Screen:getWidth() - 2 * px(24) - 2 * px(18)
    local focused = self.focus.zone == "list" and self.focus.i == n
    local dur = Music.duration(p.song)
    return FrameContainer:new{
        background = focused and FOCUS or nil, bordersize = 0, radius = px(12),
        padding = 0, padding_left = px(8), padding_right = px(8), padding_top = px(5), padding_bottom = px(5),
        ends(text(p.song.title, 17, { bold = focused, max = inner - px(80) }),
            text(dur > 0 and Mp3.time(dur) or "", 16, { color = DIM }), inner - px(16)),
    }
end

--- The "Up next" card: the next 3, each in its frame (to move the focus).
function Player:card()
    local w = Screen:getWidth()
    local c = Music.current()
    self.up_next = Music.upNext(3)
    self.next_frames = {}
    local card = VerticalGroup:new{ align = "left",
        text(_("UP NEXT"), 14, { bold = true, color = DIM }), VerticalSpan:new{ width = px(4) } }
    if #self.up_next == 0 then
        card[#card + 1] = text(c and _("This is the last one in the list") or "—", 17, { color = DIM })
    end
    for n in ipairs(self.up_next) do
        self.next_frames[n] = frame(self:nextRow(n))
        card[#card + 1] = self.next_frames[n]
    end
    Music.saveDurations()
    return FrameContainer:new{
        background = CARD, bordersize = 0, radius = px(22), padding = px(14),
        padding_left = px(18), padding_right = px(18), width = w - 2 * px(24),
        card,
    }
end

--- The five buttons, centered across the screen; each in its own frame.
function Player:buttonRow()
    local e = Music.status()
    local row = HorizontalGroup:new{ align = "center" }
    self.button_frames = {}
    for n, id in ipairs(BUTTONS) do
        if n > 1 then row[#row + 1] = HorizontalSpan:new{ width = px(14) } end
        self.button_frames[n] = frame(self:button(id, self.focus.zone == "buttons" and self.focus.i == n, e))
        row[#row + 1] = self.button_frames[n]
    end
    return centered(row, Screen:getWidth())
end

--- Repaints only the given buttons (the one losing the focus and the one getting it, or ▶ / ‖).
function Player:repaintButtons(which)
    local e = Music.status()
    for _k, n in ipairs(which) do
        local fr = self.button_frames and self.button_frames[n]
        if not (fr and fr.dimen and fr.dimen.x) then
            return self:repaintPart(self.buttons_frame, self:buttonRow())
        end
        local focused = self.focus.zone == "buttons" and self.focus.i == n
        if not self:repaintPart(fr, self:button(BUTTONS[n], focused, e)) then return false end
    end
    return true
end

--- Moves the focus and repaints only what changes: a button or the card rows.
function Player:moveFocus(new)
    local old = self.focus
    self.focus = new
    local ok = true
    for _k, f in ipairs({ old, new }) do
        if f.zone == "buttons" then
            ok = self:repaintButtons({ f.i }) and ok
        elseif self.next_frames and self.next_frames[f.i] then
            ok = self:repaintPart(self.next_frames[f.i], self:nextRow(f.i), CARD) and ok
        end
    end
    if not ok then self:redraw() end
end

--- Another song: title, progress, buttons and "Up next", without the bar, pills or footer.
-- If the number of next songs changes (and with it the card's height), the whole screen.
function Player:changeTrack()
    self.focus = { zone = "buttons", i = 3 }
    if #Music.upNext(3) ~= #(self.up_next or {}) then return self:redraw() end
    local ok = self:repaintPart(self.header_frame, self:header())
    ok = self:repaintPart(self.progress_frame, self:progressGroup()) and ok
    ok = self:repaintButtons({ 1, 2, 3, 4, 5 }) and ok
    ok = self:repaintPart(self.card_frame, self:card()) and ok
    if not ok then self:redraw() end
end

--- The volume pill, always as wide as "Volume 150 %" (does not move the others).
function Player:volumePill()
    local p = pill(T(_("Volume %1 %"), Music.volume()))
    local width = pill(T(_("Volume %1 %"), 150)):getSize().w
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = p:getSize().h }, p }
end

function Player:progressGroup()
    local w = Screen:getWidth()
    local width = w - 2 * px(32)
    local e = Music.status()
    local c = Music.current()
    local dur = (e.dur and e.dur > 0) and e.dur or (c and Music.duration(c)) or 0
    local pos = math.min(e.pos or 0, dur > 0 and dur or math.huge)
    self.shown_pos = pos
    local bar = ProgressWidget:new{
        width = width, height = px(12), percentage = dur > 0 and pos / dur or 0,
        radius = px(6), bordersize = 0, margin_h = 0, margin_v = 0,
        bgcolor = PILL, fillcolor = BLACK,
    }
    local times = ends(text(Mp3.time(pos), 17, { bold = true }),
        text(dur > 0 and Mp3.time(dur) or "--:--", 17, { color = DIM }), width)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = px(56) },
        VerticalGroup:new{ align = "center", bar, VerticalSpan:new{ width = px(8) }, times } }
end

--- A button: circle (previous, next), pill (−15, +15) or the black play circle, with a gray ring
-- when focused. SVG icons; the drawing is the fallback.
function Player:button(id, focused, e)
    local suffix = focused and "_focus" or ""
    if id == "play" then
        local size = px(100)
        local side = size + 2 * px(4) + 2 * px(5)
        local paused_icon = e.state == "playing"
        return icon((paused_icon and "pause" or "play") .. suffix, side, side, WHITE, function()
            local circle = FrameContainer:new{
                background = BLACK, bordersize = 0, radius = size / 2, padding = 0,
                CenterContainer:new{ dimen = Geom:new{ w = size, h = size },
                    text(paused_icon and I.pause or I.play, 38, { color = WHITE }) },
            }
            return FrameContainer:new{
                bordersize = px(5), color = focused and FOCUS or WHITE, background = WHITE,
                radius = size / 2 + px(9), padding = px(4), circle,
            }
        end)
    end
    local width, height, content
    local is_pill = id == "minus" or id == "plus"
    if is_pill then
        width, height = px(76), px(52)
        content = text(id == "minus" and "−15" or "+15", 19, { bold = true })
    else
        width, height = px(66), px(66)
        content = text(id == "prev" and I.prev or I.next, 24)
    end
    local drawn = function()
        return FrameContainer:new{
            background = focused and FOCUS or WHITE, bordersize = px(2), color = BLACK,
            radius = height / 2, padding = 0,
            CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, content },
        }
    end
    local W, H = width + 2 * px(2), height + 2 * px(2)
    if not is_pill then return icon(id .. suffix, W, H, WHITE, drawn) end
    -- −15 / +15: the pill is an SVG and the text goes on top
    local bg = icon("pill" .. suffix, W, H, WHITE, function() return nil end)
    if not bg then return drawn() end
    local dimen = Geom:new{ w = W, h = H }
    return OverlapGroup:new{ dimen = dimen, bg, CenterContainer:new{ dimen = dimen, content } }
end

function Player:onMusicChange(change)
    if change == "pos" then
        local e = Music.status()
        local pos = e.pos or 0
        -- every 30 s, or right after a seek (each repaint costs CPU the music also uses)
        if math.floor(pos / 30) == math.floor((self.shown_pos or 0) / 30)
            and math.abs(pos - (self.shown_pos or 0)) < 32 then return end
        self:repaintPart(self.progress_frame, self:progressGroup())
        return
    end
    if change == "volume" then
        self:repaintPart(self.volume_frame, self:volumePill())
        return
    end
    if change == "state" then
        local state = Music.status().state
        if state == "playing" or state == "paused" then
            -- only the ▶ / ‖ button changes (the bar's ♪ is updated by updateStatus)
            self:repaintButtons({ 3 })
            return
        end
    end
    if change == "track" then return self:changeTrack() end
    self:redraw()
end

function Player:activateButton(id)
    if id == "prev" then Music.prev()
    elseif id == "minus" then Music.move(-15)
    elseif id == "play" then Music.toggle()
    elseif id == "plus" then Music.move(15)
    elseif id == "next" then Music.next(true)
    end
end

function Player:onLeft()
    if self.focus.zone == "buttons" and self.focus.i > 1 then
        self.focus.i = self.focus.i - 1
        if not self:repaintButtons({ self.focus.i + 1, self.focus.i }) then self:redraw() end
    end
    return true
end

function Player:onRight()
    if self.focus.zone == "buttons" and self.focus.i < #BUTTONS then
        self.focus.i = self.focus.i + 1
        if not self:repaintButtons({ self.focus.i - 1, self.focus.i }) then self:redraw() end
    end
    return true
end

function Player:onDown()
    if self.focus.zone == "buttons" then
        if #(self.up_next or {}) > 0 then self:moveFocus{ zone = "list", i = 1 } end
    elseif self.focus.i < #self.up_next then
        self:moveFocus{ zone = "list", i = self.focus.i + 1 }
    end
    return true
end

function Player:onUp()
    if self.focus.zone ~= "list" then return true end
    if self.focus.i > 1 then
        self:moveFocus{ zone = "list", i = self.focus.i - 1 }
    else
        self:moveFocus{ zone = "buttons", i = 3 }
    end
    return true
end

function Player:onActivate()
    if self.focus.zone == "list" then
        local p = self.up_next and self.up_next[self.focus.i]
        if p then Music.play(p.index, 0) end
    else
        self:activateButton(BUTTONS[self.focus.i])
    end
    return true
end

function Player:onPageNext() Music.next(true) return true end
function Player:onPagePrev() Music.prev() return true end

function Player:onMenu()
    M.menu(self)
    return true
end

---------------------------------------------------------------- song list

local Songs = Screen_:extend{
    name = "k3aplayer_songs",
    title = _("Songs"),
    page = 1,
    from_player = false, -- opened from the player: after choosing, go back to it
}

local function totalText()
    local n = #Music.songs()
    local t, all = Music.total()
    local s = n == 1 and _("1 song") or T(_("%1 songs"), n)
    if all and t > 0 then
        local h, m = math.floor(t / 3600), math.floor(t / 60) % 60
        s = s .. " · " .. (h > 0 and T(_("%1 h %2 min"), h, m) or T(_("%1 min"), m))
    end
    return s
end

--- One row: number (or ♪ if playing), title and duration. The playing one is black.
function Songs:row(i, c, focused, width)
    local playing = (select(2, Music.current())) == i and Music.active()
    local color = playing and WHITE or BLACK
    local dur = Music.duration(c)
    local left = HorizontalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = px(30), h = px(24) },
            text(playing and I.music or tostring(i), 15, { bold = focused or playing, color = playing and WHITE or DIM }) },
        HorizontalSpan:new{ width = px(12) },
        text(c.title, 18, { bold = focused or playing, color = color, max = width - px(130) }),
    }
    local right = text(dur > 0 and Mp3.time(dur) or "", 15, { color = playing and WHITE or DIM })
    local bg = nil
    if playing then bg = focused and Blitbuffer.COLOR_GRAY_4 or BLACK
    elseif focused then bg = FOCUS end
    return FrameContainer:new{
        background = bg, bordersize = 0, radius = px(18), padding = 0,
        padding_left = px(14), padding_right = px(14), padding_top = px(10), padding_bottom = px(10),
        ends(left, right, width - px(28)),
    }
end

--- Short name of the music folder for the list header ("music/").
local function folderLabel()
    local f = Music.folder()
    return (f:match("([^/]+)/*$") or f) .. "/"
end

function Songs:build()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local list = Music.songs()
    if not self.focus then
        local _k, i = Music.current()
        self.focus = i and { zone = "rows", i = i } or (#list > 0 and { zone = "rows", i = 1 } or { zone = "buttons", i = 1 })
    end
    local width = w - 2 * px(16)

    -- how many rows fit: what the bar, header and footer leave
    local row_h = px(50)
    if list[1] then row_h = self:row(1, list[1], false, width):getSize().h + px(4) end
    local bar_h = self.bar_height or px(60)
    local free = h - bar_h - px(84) - px(50) - px(16)
    self.per_page = math.max(1, math.floor(free / row_h))
    self.pages = math.max(1, math.ceil(#list / self.per_page))
    if self.focus.zone == "rows" then
        self.page = math.floor((self.focus.i - 1) / self.per_page) + 1
    end
    self.page = math.max(1, math.min(self.page, self.pages))

    -- header: folder, total and the "All" and "Shuffle" buttons
    self.head_buttons_frame = frame(self:headButtons())
    local info = VerticalGroup:new{ align = "left",
        text(folderLabel(), 22, { bold = true, max = w / 2 }),
        text(totalText(), 15, { color = DIM }) }
    local header = FrameContainer:new{ bordersize = 0, padding = 0,
        padding_left = px(24), padding_right = px(24), padding_top = px(16), padding_bottom = px(12),
        ends(info, self.head_buttons_frame, w - 2 * px(24)) }

    -- each row in its frame: moving the focus inside the page repaints only two rows
    self.row_frames = {}
    local rows = VerticalGroup:new{ align = "center" }
    if #list == 0 then
        rows[#rows + 1] = text(T(_("There are no MP3 files in %1"), Music.folder()), 17, { color = DIM, max = width })
    end
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#list, first + self.per_page - 1) do
        self.row_frames[i] = frame(self:row(i, list[i], self.focus.zone == "rows" and self.focus.i == i, width))
        rows[#rows + 1] = self.row_frames[i]
        rows[#rows + 1] = VerticalSpan:new{ width = px(4) }
    end
    Music.saveDurations()

    local content = VerticalGroup:new{ align = "center", header, rows }
    local footer = FrameContainer:new{ bordersize = 0, padding = 0,
        padding_left = px(20), padding_right = px(20), padding_bottom = px(12), padding_top = px(8),
        OverlapGroup:new{
            dimen = Geom:new{ w = w - px(40), h = px(30) },
            LeftContainer:new{ dimen = Geom:new{ w = w - px(40), h = px(30) },
                text(_("▲ ▼ choose · Press play"), 13, { color = DIM }) },
            CenterContainer:new{ dimen = Geom:new{ w = w - px(40), h = px(30) },
                pill(T(_("Page %1 of %2"), self.page, self.pages), { size = 13 }) },
            RightContainer:new{ dimen = Geom:new{ w = w - px(40), h = px(30) },
                text(_("Back return"), 13, { color = DIM }) },
        } }
    self:assemble(content, footer)
end

--- "All" and "Shuffle", with the focus if they have it.
function Songs:headButtons()
    local fb = self.focus.zone == "buttons" and self.focus.i
    local all = FrameContainer:new{
        background = fb == 1 and Blitbuffer.COLOR_GRAY_4 or BLACK, bordersize = 0, radius = px(20),
        padding = 0, padding_left = px(16), padding_right = px(16), padding_top = px(8), padding_bottom = px(8),
        text(I.play .. "  " .. _("All"), 16, { bold = true, color = WHITE }),
    }
    local shuffle = FrameContainer:new{
        background = fb == 2 and FOCUS or WHITE, bordersize = px(2), color = BLACK, radius = px(20),
        padding = 0, padding_left = px(14), padding_right = px(14), padding_top = px(6), padding_bottom = px(6),
        text(I.shuffle .. "  " .. _("Shuffle"), 16, { bold = true }),
    }
    return HorizontalGroup:new{ align = "center", all, HorizontalSpan:new{ width = px(10) }, shuffle }
end

--- Another song or play / pause: the playing row changes (♪ and black background); only the rows
-- of the page are repainted.
function Songs:onMusicChange(change)
    if change ~= "track" and change ~= "state" then return end
    local list = Music.songs()
    local width = Screen:getWidth() - 2 * px(16)
    local ok = next(self.row_frames or {}) ~= nil
    for i, fr in pairs(self.row_frames or {}) do
        if list[i] then
            local focused = self.focus.zone == "rows" and self.focus.i == i
            ok = self:repaintPart(fr, self:row(i, list[i], focused, width)) and ok
        end
    end
    if not ok then self:redraw() end
end

--- Moves the focus. Inside the same page only what changes is repainted (two rows, or a row and
-- the buttons above); if the new row is on another page, the whole screen.
function Songs:moveFocus(new)
    local old = self.focus
    self.focus = new
    local frames = self.row_frames or {}
    if new.zone == "rows" and not frames[new.i] then return self:redraw() end
    local list = Music.songs()
    local width = Screen:getWidth() - 2 * px(16)
    local ok = true
    for k, f in ipairs({ old, new }) do
        if f.zone == "buttons" then
            if k == 1 or old.zone ~= "buttons" then
                ok = self:repaintPart(self.head_buttons_frame, self:headButtons()) and ok
            end
        elseif frames[f.i] and list[f.i] then
            local focused = new.zone == "rows" and new.i == f.i
            ok = self:repaintPart(frames[f.i], self:row(f.i, list[f.i], focused, width)) and ok
        end
    end
    if not ok then self:redraw() end
end

function Songs:onDown()
    local n = #Music.songs()
    if self.focus.zone == "buttons" then
        if n == 0 then return true end
        self:moveFocus{ zone = "rows", i = (self.page - 1) * self.per_page + 1 }
    elseif self.focus.i < n then
        self:moveFocus{ zone = "rows", i = self.focus.i + 1 }
    end
    return true
end

function Songs:onUp()
    if self.focus.zone == "buttons" then return true end
    if self.focus.i > 1 then
        self:moveFocus{ zone = "rows", i = self.focus.i - 1 }
    else
        self:moveFocus{ zone = "buttons", i = 1 }
    end
    return true
end

function Songs:onLeft()
    if self.focus.zone == "buttons" and self.focus.i == 2 then
        self:moveFocus{ zone = "buttons", i = 1 }
    end
    return true
end

function Songs:onRight()
    if self.focus.zone == "buttons" and self.focus.i == 1 then
        self:moveFocus{ zone = "buttons", i = 2 }
    end
    return true
end

function Songs:turnPage(delta)
    local p = math.max(1, math.min(self.pages, self.page + delta))
    if p == self.page then return end
    self.page = p
    self.focus = { zone = "rows", i = (p - 1) * self.per_page + 1 }
    self:redraw()
end

function Songs:onPageNext() self:turnPage(1) return true end
function Songs:onPagePrev() self:turnPage(-1) return true end

--- After choosing: to the player (if we came from it, back to it).
function Songs:goToPlayer()
    UIManager:close(self)
    if not self.from_player then
        UIManager:show(Player:new{})
    end
end

function Songs:onActivate()
    if self.focus.zone == "buttons" then
        if #Music.songs() == 0 then return true end
        Music.playAll(self.focus.i == 2)
    else
        Music.play(self.focus.i, 0)
    end
    self:goToPlayer()
    return true
end

function Songs:onMenu() return true end

---------------------------------------------------------------- player menu

M.Player = Player
M.Songs = Songs

M.KEYS_HELP = _([[
Anywhere in KOReader
  Alt + Space    play / pause
  Alt + F        next song
  Alt + M        open the player
  Volume + / −   music volume (with a song loaded)

In the player
  ◀ ▶            move the focus between buttons
  ▲ ▼            go down to "Up next" and back
  Press          activate
  Page keys      next / previous song
  Menu           options
  Back           return; the music keeps playing

In the song list
  ▲ ▼  choose · Press  play · page keys  turn the page]])

function M.menu(player)
    local options = {}
    local function option(sym, t, action) options[#options + 1] = { sym .. "   " .. t, action } end
    local left = Music.sleepLeft()
    option(I.clock, T(_("Sleep timer · %1"), left and T(_("%1 min"), left) or _("off")), function()
        local o = {}
        for _k, m in ipairs({ 15, 30, 45, 60, 90 }) do
            o[#o + 1] = { text = T(_("%1 minutes"), m), on_tap = function() Music.sleepIn(m) end }
        end
        o[#o + 1] = { text = _("No timer"), current = not left, on_tap = function() Music.sleepIn(nil) end }
        choose(_("Stop the music in…"), o)
    end)
    option(I.volume, T(_("Volume · %1 %"), Music.volume()), function()
        local o = {}
        for _k, v in ipairs({ 20, 40, 60, 70, 80, 100, 120, 150 }) do
            o[#o + 1] = { text = v .. " %", current = Music.volume() == v, on_tap = function() Music.volume(v) end }
        end
        choose(_("Volume"), o)
    end)
    option(I["repeat"], T(_("Repeat · %1"), REPEAT_TEXT[Music.repeatMode()]), function()
        local o = {}
        for _k, m in ipairs(Music.REPEAT_MODES) do
            o[#o + 1] = { text = T(_("Repeat: %1"), REPEAT_TEXT[m]), current = Music.repeatMode() == m,
                on_tap = function() Music.repeatMode(m) end }
        end
        choose(_("Repeat"), o)
    end)
    option(I.shuffle, T(_("Shuffle · %1"), Music.shuffle() and _("on") or _("off")), function()
        Music.shuffle(not Music.shuffle())
    end)
    option(I.go, _("Go to minute…"), function()
        local dialog
        dialog = InputDialog:new{
            title = _("Go to minute"),
            description = _("Type minutes:seconds (for example 1:30) or just the minutes."),
            input = "", input_hint = "1:30",
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Go"), is_enter_default = true, callback = function()
                    local t = dialog:getInputText()
                    UIManager:close(dialog)
                    local m, s = t:match("^%s*(%d+)%s*[:%.]%s*(%d+)%s*$")
                    local sec = m and (tonumber(m) * 60 + tonumber(s))
                        or (t:match("^%s*(%d+)%s*$") and tonumber(t) * 60)
                    if sec then Music.seek(sec) end
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end)
    option(I.list, _("Song list"), function()
        UIManager:show(Songs:new{ from_player = true })
    end)
    option(I.stop, _("Stop the music"), function()
        Music.stop()
        UIManager:close(player)
    end)
    option(I.keys, _("Player keys"), function()
        UIManager:show(InfoMessage:new{ text = M.KEYS_HELP, monospace_font = true })
    end)
    local Panel = require("k3aplayer_panel")
    UIManager:show(Panel:new{ title = _("Music options"), options = options, top = player.bar_height },
        nil, nil, 0, player.bar_height)
end

--- Opens the music: the player if something is loaded; otherwise the list. No songs: a notice.
function M.open()
    local top = UIManager:getNthTopWidget()
    if top and (top.name == "k3aplayer_player" or top.name == "k3aplayer_songs") then return end
    pcall(function() require("k3aplayer_jit").prepare() end)
    local list = Music.songs(true)
    if #list == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("There are no MP3 files in %1.\n\nConnect the Kindle over USB, copy MP3 files into that folder and open the player again."),
                Music.folder()),
        })
        return
    end
    if Music.active() then
        UIManager:show(Player:new{})
    else
        UIManager:show(Songs:new{})
    end
end

return M
