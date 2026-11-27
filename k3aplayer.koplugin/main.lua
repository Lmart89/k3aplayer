--[[--
K3 Audio Player for KOReader: plays the MP3 files of the Kindle 3's music folder through the
Kindle's own GStreamer, in a separate process (k3aplayer_engine), so the music keeps playing while
you read.

    Main menu → Tools → Music player
    Alt + Space play / pause · Alt + F next song · Alt + M open the player · volume keys

Also available as Dispatcher actions (gestures, profiles, hotkeys): open the player, play / pause,
next song, previous song.

@module koplugin.K3APlayer
--]]--

local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
-- English only: KOReader's gettext would translate just the words its own catalog knows
-- ("off", "About"…) and leave the rest in English, mixing two languages
local _ = function(s) return s end
local T = require("ffi/util").template

local Music = require("k3aplayer_music")

local K3APlayer = WidgetContainer:extend{
    name = "k3aplayer",
    is_doc_only = false,
}

local volume_notice = nil

--- The global music keys (k3aplayer_keys): "toggle", "next", "open", "up" and "down" (volume).
local function onKey(action)
    if action == "toggle" then
        Music.toggle()
    elseif action == "next" then
        if Music.active() then Music.next(true) end
    elseif action == "open" then
        require("k3aplayer_screens").open()
    elseif action == "up" or action == "down" then
        Music.volume(Music.volume() + (action == "up" and 10 or -10))
        -- the player already shows it in its pill; elsewhere, a single notice after the last press
        -- (each notice repaints the screen below, which is slow on the K3)
        local top = UIManager:getNthTopWidget()
        if top and top.name == "k3aplayer_player" then return end
        if volume_notice then UIManager:unschedule(volume_notice) end
        volume_notice = function()
            volume_notice = nil
            UIManager:show(InfoMessage:new{ text = "\u{F028}  " .. T(_("Volume %1 %"), Music.volume()), timeout = 1 })
        end
        UIManager:scheduleIn(0.7, volume_notice)
    end
end

local function keysEnabled()
    return G_reader_settings:nilOrTrue("k3aplayer_keys")
end

local function applyKeys()
    local Keys = require("k3aplayer_keys")
    if keysEnabled() then
        Keys.enable(onKey, function() return Music.current() ~= nil end)
    else
        Keys.disable()
    end
end

function K3APlayer:onDispatcherRegisterActions()
    Dispatcher:registerAction("k3aplayer_open", { category = "none", event = "K3APlayerOpen",
        title = _("Music player: open"), general = true })
    Dispatcher:registerAction("k3aplayer_toggle", { category = "none", event = "K3APlayerToggle",
        title = _("Music player: play / pause"), general = true })
    Dispatcher:registerAction("k3aplayer_next", { category = "none", event = "K3APlayerNext",
        title = _("Music player: next song"), general = true })
    Dispatcher:registerAction("k3aplayer_prev", { category = "none", event = "K3APlayerPrev",
        title = _("Music player: previous song"), general = true })
end

function K3APlayer:init()
    Music.plugin_dir = self.path
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if Device:hasKeys() then applyKeys() end
end

function K3APlayer:addToMainMenu(menu_items)
    menu_items.k3aplayer = {
        text_func = function() return Music.menuText() end,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open the player"),
                callback = function() require("k3aplayer_screens").open() end,
            },
            {
                text_func = function()
                    return Music.playing() and _("Pause") or _("Play")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Music.toggle()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Next song"),
                enabled_func = function() return Music.active() end,
                keep_menu_open = true,
                callback = function() Music.next(true) end,
            },
            {
                text = _("Stop the music"),
                enabled_func = function() return Music.active() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Music.stop()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                separator = true,
            },
            {
                text_func = function() return T(_("Music folder: %1"), Music.folder()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local PathChooser = require("ui/widget/pathchooser")
                    UIManager:show(PathChooser:new{
                        path = Music.folder(),
                        select_directory = true,
                        select_file = false,
                        onConfirm = function(path)
                            if Music.active() then Music.stop() end
                            Music.folder(path)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text = _("Music keys (Alt + Space / F / M, volume)"),
                enabled_func = function() return Device:hasKeys() end,
                checked_func = keysEnabled,
                callback = function()
                    G_reader_settings:saveSetting("k3aplayer_keys", not keysEnabled())
                    applyKeys()
                end,
            },
            {
                text = _("Player keys"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = require("k3aplayer_screens").KEYS_HELP,
                        monospace_font = true })
                end,
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(require("k3aplayer_about"):new{})
                end,
            },
        },
    }
end

function K3APlayer:onK3APlayerOpen() require("k3aplayer_screens").open() return true end
function K3APlayer:onK3APlayerToggle() Music.toggle() return true end
function K3APlayer:onK3APlayerNext() if Music.active() then Music.next(true) end return true end
function K3APlayer:onK3APlayerPrev() Music.prev() return true end

--- The Kindle goes to sleep: the music pauses (it stays paused on wake-up).
function K3APlayer:onSuspend()
    Music.onSuspend()
end

--- KOReader quits or restarts: close the audio engine.
function K3APlayer:onExit() Music.shutdown() end
function K3APlayer:onRestart() Music.shutdown() end

return K3APlayer
