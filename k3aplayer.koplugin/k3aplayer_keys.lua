--[[--
K3 Audio Player: global music keys, read before any screen with KOReader's input hook
(Input:registerEventAdjustHook, which chains with other hooks), without changing the core:

  * Alt + Space plays / pauses, Alt + F skips to the next song, Alt + M opens the player (like the
    Kindle 3's own music player). While typing (a text box or the on-screen keyboard) Alt keeps
    typing as usual.
  * The volume keys raise / lower the music volume while a song is loaded: KOReader does not open
    their input device on the K3, it is opened here.

The hook cannot be removed: it stays installed and does nothing while the keys are disabled.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")

local Keys = {}

local EV_KEY = 1
local PRESSED = 1

local handler = nil -- function(action): "toggle", "next", "open", "up", "down"
local installed = false

local ALT_KEYS = { [" "] = "toggle", F = "next", M = "open" }
local VOLUME = { [114] = "VMinus", [115] = "VPlus" } -- KEY_VOLUMEDOWN / KEY_VOLUMEUP

--- Is the user typing? (text box or on-screen keyboard)
local function typing()
    local top = UIManager:getNthTopWidget()
    if not top then return false end
    return top._input_widget ~= nil or top.name == "VirtualKeyboard"
end

local function run(action)
    UIManager:nextTick(function()
        if handler then handler(action) end
    end)
end

--- What each key does. Kept apart from the hook so it can be tested without a device.
-- mods: Input's modifiers (Alt pressed…). Returns true if the key is swallowed (must not reach
-- the screens).
function Keys.process(name, value, mods, music_loaded)
    if not handler then return false end
    if (name == "VPlus" or name == "VMinus") and music_loaded then
        if value == PRESSED then run(name == "VPlus" and "up" or "down") end
        return true
    end
    if ALT_KEYS[name] and mods and mods.Alt and not typing() then
        if value == PRESSED then run(ALT_KEYS[name]) end
        return true -- neither the press, nor the repeat, nor the release reach the screens
    end
    return false
end

--- The volume keys' device ("volume" in /proc/bus/input/devices; event2 on the K3).
local function openVolume()
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    for block in (text .. "\n\n"):gmatch("(.-)\n\n") do
        if block:match('N: Name="volume"') then
            local ev = block:match("Handlers=.-(event%d+)")
            if ev then
                local ok, err = pcall(Device.input.open, Device.input, "/dev/input/" .. ev)
                if not ok then require("logger").warn("[K3APlayer] volume keys:", err) end
            end
            return
        end
    end
end

--- Enables the global keys. on_action(action) is called for each key; is_loaded() tells whether a
-- song is loaded (only then the volume keys belong to the music).
function Keys.enable(on_action, is_loaded)
    handler = on_action
    Keys.is_loaded = is_loaded
    if installed or not Device:hasKeys() then return end
    installed = true
    if Device:isKindle() then pcall(openVolume) end
    Device.input:registerEventAdjustHook(function(input, ev)
        if ev.type ~= EV_KEY or not handler then return end
        -- the volume keys are not in KOReader's K3 key map (they arrive as 114/115)
        local name = input.event_map[ev.code] or VOLUME[ev.code]
        local loaded = Keys.is_loaded and Keys.is_loaded() or false
        if name and Keys.process(name, ev.value, input.modifiers, loaded) then
            ev.code = 0 -- no name in the key map: KOReader ignores it
        end
    end)
end

function Keys.disable()
    handler = nil
end

return Keys
