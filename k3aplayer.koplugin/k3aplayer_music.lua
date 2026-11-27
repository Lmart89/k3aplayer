--[[--
K3 Audio Player: the music itself. Controls the audio engine (k3aplayer_engine, a separate process
with GStreamer) and keeps the song list, play order, repeat, shuffle, the sleep timer and the last
song played. The screens (k3aplayer_screens) only read from here and ask for things.

    local Music = require("k3aplayer_music")
    Music.songs()               songs in the music folder: { {path, name, title, size}, … }, sorted
    Music.play(i, from)  Music.toggle()  Music.next()  Music.prev()
    Music.move(s)  Music.seek(s)  Music.volume(v)  Music.stop()  Music.shutdown()
    Music.status()              { state, pos, dur, … } as the engine reports it
    Music.listen(f)             f(change) when something changes ("track", "state", "pos", "settings")

The engine takes commands on a FIFO and writes its status to a file, read here once a second while
playing. When a song ends the next one starts. While playing, the Kindle does not fall asleep.
--]]--

-- This code runs once a second and does not need the JIT. That way it does not fill LuaJIT's trace
-- memory, which on the K3 is needed to paint the screen (it is painted in Lua, pixel by pixel).
if jit then jit.off(true, true) end

local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
-- English only: KOReader's gettext would translate just the words its own catalog knows
-- ("off", "About"…) and leave the rest in English, mixing two languages
local _ = function(s) return s end
local T = require("ffi/util").template

math.randomseed(os.time())

-- FFI (engine FIFO, pid) and the MP3 parser load on first use
local C
local function system()
    if not C then
        local ffi = require("ffi")
        require("ffi/posix_h")
        C = ffi.C
    end
    return C
end

local Music = {
    DEFAULT_FOLDER = "/mnt/us/music",
    DIR = "/tmp/k3aplayer",
    REPEAT_MODES = { "all", "one", "off" },
    plugin_dir = nil, -- set by main.lua (absolute path of k3aplayer.koplugin)
}

local SETTING = "k3aplayer"                    -- { vol, repeat_mode, shuffle, folder, last = { path, pos } }
local SETTING_DUR = "k3aplayer_durations"      -- { ["name|size"] = seconds }

local list = nil       -- songs in the folder
local order = nil      -- indexes into list, in play order (shuffled or not)
local step = 0         -- current position inside order
local current = nil    -- index in list of the current song
local S = { state = "stopped", pos = 0, dur = 0 }
local listeners = {}
local pending = {}     -- commands waiting for the engine to start
local starting = false
local end_handled = nil
local errors_in_row = 0
local mark = 0         -- id of the last requested song: the engine echoes it in its status
local sleep = nil      -- { time = os.time() when it pauses, task }
local last_keepawake = 0
local last_saved = 0

---------------------------------------------------------------- settings

local function settings()
    Music._s = Music._s or G_reader_settings:readSetting(SETTING) or {}
    local s = Music._s
    s.vol = s.vol or 100
    s.repeat_mode = s.repeat_mode or "all"
    return s
end

local function saveSettings()
    G_reader_settings:saveSetting(SETTING, settings())
end

local function notify(change)
    for f in pairs(listeners) do
        local ok, err = pcall(f, change)
        if not ok then logger.warn("[K3APlayer] listener:", err) end
    end
    -- the badge in the top bar (♪ ▶ / ♪ ‖) of the screen on top
    if change == "state" or change == "track" then
        local top = UIManager:getNthTopWidget()
        if top and top.updateStatus then top:updateStatus() end
    end
end

function Music.listen(f) listeners[f] = true end
function Music.forget(f) listeners[f] = nil end

---------------------------------------------------------------- songs

function Music.folder(path)
    local s = settings()
    if path then
        s.folder = path
        saveSettings()
        list, order, current = nil, nil, nil
    end
    return s.folder or Music.DEFAULT_FOLDER
end

local function titleOf(name)
    local t = name:gsub("%.[^%.]+$", "")
    -- "01 Joy to the World" → "Joy to the World" (the track number of many albums)
    local without = t:gsub("^%d+%s*[%-%._]?%s+", "")
    if without ~= "" then t = without end
    return t
end

--- MP3 songs in the music folder, sorted by name. Re-read with refresh.
function Music.songs(refresh)
    if list and not refresh then return list end
    local lfs = require("libs/libkoreader-lfs")
    local found = {}
    local folder = Music.folder()
    local ok = pcall(function()
        for name in lfs.dir(folder) do
            if name:lower():match("%.mp3$") and name:sub(1, 1) ~= "." then
                local path = folder .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "file" then
                    found[#found + 1] = { path = path, name = name, title = titleOf(name), size = attr.size }
                end
            end
        end
    end)
    if not ok then found = {} end
    table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
    local function signature(l)
        local t = {}
        for i, c in ipairs(l) do t[i] = c.name end
        return table.concat(t, "\n")
    end
    if list and signature(list) == signature(found) then return list end -- nothing changed
    -- keep the current song even if its position in the list changed
    local current_path = current and list and list[current] and list[current].path
    list = found
    current = nil
    for i, c in ipairs(list) do
        if c.path == current_path then current = i end
    end
    order = nil
    if current then
        order = {}
        for i = 1, #list do order[i] = i end
        step = current
    end
    return list
end

local durations = nil

--- Duration in seconds (from the header; remembered by name and size).
function Music.duration(c)
    durations = durations or G_reader_settings:readSetting(SETTING_DUR) or {}
    local key = c.name .. "|" .. tostring(c.size)
    if not durations[key] then
        local info = require("k3aplayer_mp3").parse(c.path)
        durations[key] = info and math.floor(info.dur + 0.5) or 0
        Music._dur_changed = true
    end
    return durations[key]
end

--- Sum of the known durations and whether all of them are known.
function Music.total()
    local t, all = 0, true
    durations = durations or G_reader_settings:readSetting(SETTING_DUR) or {}
    for _k, c in ipairs(Music.songs()) do
        local d = durations[c.name .. "|" .. tostring(c.size)]
        if d then t = t + d else all = false end
    end
    return t, all
end

function Music.saveDurations()
    if Music._dur_changed and durations then
        G_reader_settings:saveSetting(SETTING_DUR, durations)
        Music._dur_changed = false
    end
end

---------------------------------------------------------------- engine

local function fifoPath() return Music.DIR .. "/commands" end

local function writeFifo(line)
    local sys = system()
    local fd = sys.open(fifoPath(), require("bit").bor(sys.O_WRONLY, sys.O_NONBLOCK))
    if fd < 0 then return false end -- no reader: the engine is not running
    local s = line .. "\n"
    sys.write(fd, s, #s)
    sys.close(fd)
    return true
end

local function flushPending()
    while #pending > 0 do
        if not writeFifo(pending[1]) then return false end
        table.remove(pending, 1)
    end
    return true
end

local heartbeat -- below

--- Absolute path of KOReader's folder (where its luajit is).
local function koreaderDir()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.currentdir()
end

local function absolute(path, base)
    if path:sub(1, 1) == "/" then return path end
    return base .. "/" .. path:gsub("^%./", "")
end

--- Full path of the engine log (KOReader's data folder is often just "." on the Kindle).
function Music.logPath()
    return absolute(DataStorage:getDataDir() .. "/k3aplayer.log", koreaderDir())
end

local function startEngine()
    if starting then return end
    starting = true
    os.execute("mkdir -p " .. Music.DIR .. " && rm -f " .. Music.DIR .. "/status")
    local base = koreaderDir()
    local engine = absolute((Music.plugin_dir or "plugins/k3aplayer.koplugin") .. "/k3aplayer_engine.lua", base)
    local cmd = string.format("cd '%s' && ./luajit '%s' %s %d > '%s' 2>&1 &",
        base, engine, Music.DIR, system().getpid(), absolute(Music.logPath(), base))
    logger.info("[K3APlayer] starting the audio engine")
    os.execute(cmd)
    local tries = 0
    local function wait()
        tries = tries + 1
        if flushPending() then
            starting = false
            UIManager:unschedule(heartbeat)
            UIManager:scheduleIn(0.5, heartbeat)
            return
        end
        if tries > 50 then -- 10 s
            starting = false
            pending = {}
            S.state, S.error = "error", _("the audio engine did not start")
            notify("state")
            return
        end
        UIManager:scheduleIn(0.2, wait)
    end
    UIManager:scheduleIn(0.3, wait)
end

local function send(line)
    if #pending == 0 and writeFifo(line) then
        UIManager:unschedule(heartbeat)
        UIManager:scheduleIn(0.3, heartbeat)
        return
    end
    pending[#pending + 1] = line
    startEngine()
end

local function readStatus()
    local f = io.open(Music.DIR .. "/status", "r")
    if not f then return nil end
    local e = {}
    for line in f:lines() do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then e[k] = v end
    end
    f:close()
    e.pos = tonumber(e.pos) or 0
    e.dur = tonumber(e.dur) or 0
    e.vol = tonumber(e.vol) or 100
    e.n = tonumber(e.n) or 0
    return e
end

---------------------------------------------------------------- play order

local function makeOrder(start_at)
    local n = #Music.songs()
    order = {}
    for i = 1, n do order[i] = i end
    if settings().shuffle then
        for i = n, 2, -1 do
            local j = math.random(i)
            order[i], order[j] = order[j], order[i]
        end
        -- the chosen song goes first
        for i, v in ipairs(order) do
            if v == start_at then
                order[1], order[i] = order[i], order[1]
                break
            end
        end
        step = 1
    else
        step = start_at or 1
    end
end

function Music.current()
    return current and Music.songs()[current], current
end

--- The n songs after the current one.
function Music.upNext(n)
    local res = {}
    local l = Music.songs()
    if not order or #l == 0 then return res end
    local p = step
    for _ = 1, n do
        p = p + 1
        if p > #order then
            if settings().repeat_mode ~= "all" then break end
            p = 1
        end
        if order[p] == current then break end
        res[#res + 1] = { index = order[p], song = l[order[p]] }
    end
    return res
end

---------------------------------------------------------------- actions

--- Plays song i of the list (from second "from").
function Music.play(i, from)
    local l = Music.songs()
    local c = l[i]
    if not c then return end
    if not order or #order ~= #l then
        makeOrder(i)
    else
        step = nil
        for p, v in ipairs(order) do
            if v == i then step = p end
        end
        if not step then makeOrder(i) end
    end
    current = i
    end_handled = nil
    local s = settings()
    S = { state = "playing", pos = from or 0, dur = 0, file = c.path }
    s.last = { path = c.path, pos = from or 0 }
    saveSettings()
    mark = mark + 1
    send("vol " .. s.vol)
    send("mark " .. mark)
    if from and from > 0 then
        send(string.format("from %d %s", from, c.path))
    else
        send("play " .. c.path)
    end
    notify("track")
end

--- The last song played and its position, if it is still in the folder.
function Music.last()
    local u = settings().last
    if not u then return nil end
    for i, c in ipairs(Music.songs()) do
        if c.path == u.path then return i, u.pos or 0, c end
    end
end

function Music.resumeLast()
    local i, pos = Music.last()
    if i then Music.play(i, pos) end
end

function Music.active()
    return current ~= nil and (S.state == "playing" or S.state == "paused")
end

function Music.playing()
    return current ~= nil and S.state == "playing"
end

function Music.status() return S end

function Music.toggle()
    if not current then
        -- nothing loaded: the last song played, or the first one of the list
        if Music.last() then return Music.resumeLast() end
        if #Music.songs() > 0 then return Music.play(1, 0) end
        return
    end
    if S.state == "playing" then
        S.state = "paused"
        send("pause")
        Music.rememberPosition(true)
    elseif S.state == "paused" then
        S.state = "playing"
        send("resume")
    else
        return Music.play(current, 0)
    end
    notify("state")
end

function Music.pause()
    if S.state == "playing" then Music.toggle() end
end

--- Next in play order; "manual" ignores "repeat one".
function Music.next(manual)
    local l = Music.songs()
    if #l == 0 then return end
    if not order then makeOrder(current or 1) end
    local s = settings()
    if not manual and s.repeat_mode == "one" and current then
        return Music.play(current, 0)
    end
    local p = step + 1
    if p > #order then
        if not manual and s.repeat_mode == "off" then
            S.state = "stopped"
            send("stop")
            notify("state")
            return
        end
        p = 1
    end
    Music.play(order[p], 0)
end

--- Previous; more than 3 s into the song, back to its start.
function Music.prev()
    if not current then return end
    if (S.pos or 0) > 3 then return Music.seek(0) end
    if not order then makeOrder(current) end
    local p = step - 1
    if p < 1 then p = #order end
    Music.play(order[p], 0)
end

function Music.seek(sec)
    if not Music.active() then return end
    S.pos = math.max(0, sec)
    send(string.format("seek %d", S.pos))
    notify("pos")
end

function Music.move(delta)
    if not Music.active() then return end
    local target = (S.pos or 0) + delta
    if S.dur and S.dur > 0 then target = math.min(target, S.dur - 1) end
    Music.seek(target)
end

function Music.volume(v)
    local s = settings()
    if v == nil then return s.vol end
    s.vol = math.max(0, math.min(150, math.floor(v + 0.5)))
    saveSettings()
    if Music.active() then send("vol " .. s.vol) end
    notify("volume")
    return s.vol
end

function Music.repeatMode(mode)
    local s = settings()
    if mode then
        s.repeat_mode = mode
        saveSettings()
        notify("settings")
    end
    return s.repeat_mode
end

function Music.shuffle(on)
    local s = settings()
    if on ~= nil then
        s.shuffle = on and true or nil
        saveSettings()
        if current then makeOrder(current) else order = nil end
        notify("settings")
    end
    return s.shuffle and true or false
end

--- Plays the whole list from the start (or shuffled).
function Music.playAll(shuffled)
    Music.shuffle(shuffled and true or false)
    local l = Music.songs()
    if #l == 0 then return end
    makeOrder(shuffled and math.random(#l) or 1)
    Music.play(order[1], 0)
end

function Music.rememberPosition(save)
    local c = Music.current()
    if not c then return end
    local s = settings()
    s.last = { path = c.path, pos = math.floor(S.pos or 0) }
    if save then saveSettings() end
end

function Music.stop()
    Music.rememberPosition(true)
    Music.sleepIn(nil)
    if current then send("stop") end
    current = nil
    S = { state = "stopped", pos = 0, dur = 0 }
    notify("state")
end

--- On KOReader exit: closes the engine (if it was running).
function Music.shutdown()
    Music.rememberPosition(true)
    Music.saveDurations()
    UIManager:unschedule(heartbeat)
    if sleep then UIManager:unschedule(sleep.task) end
    sleep = nil
    pending = {}
    if C or package.loaded["ffi/posix_h"] then pcall(writeFifo, "quit") end
    current = nil
    S = { state = "stopped", pos = 0, dur = 0 }
end

--- Sleep timer: minutes (nil removes it). When it fires, the music pauses.
function Music.sleepIn(minutes)
    if sleep then UIManager:unschedule(sleep.task) end
    sleep = nil
    if minutes and minutes > 0 then
        local task = function()
            sleep = nil
            Music.pause()
            notify("settings")
        end
        sleep = { time = os.time() + minutes * 60, task = task }
        UIManager:scheduleIn(minutes * 60, task)
    end
    notify("settings")
end

--- Minutes left on the sleep timer, or nil.
function Music.sleepLeft()
    if not sleep then return nil end
    return math.max(1, math.ceil((sleep.time - os.time()) / 60))
end

--- The Kindle goes to sleep: pause (it stays paused on wake-up).
function Music.onSuspend()
    if Music.playing() then Music.toggle() end
end

--- Badge text for the top bar: "♪ ▶", "♪ ‖" or nil.
function Music.badge()
    if not current then return nil end
    if S.state == "playing" then return "\u{F001} \u{F04B}" end
    if S.state == "paused" then return "\u{F001} \u{F04C}" end
    return nil
end

--- Text for the menu entry: what is playing, or how many songs there are.
function Music.menuText()
    local c = Music.current()
    if c and Music.active() then
        return T(_("Music player · %1 %2"), S.state == "playing" and "▶" or "‖", c.title)
    end
    return _("Music player")
end

---------------------------------------------------------------- heartbeat

local last_beat = nil
local last_rescue = 0

heartbeat = function()
    -- diagnostics: if the heartbeat (every 1 s) arrives very late, KOReader had no CPU
    local ok_t, t = pcall(function() local time = require("ui/time") return time.to_ms(time.now()) end)
    if ok_t and t then
        if last_beat and t - last_beat > 3000 then
            local late = t - last_beat
            logger.warn(string.format("[K3APlayer] KOReader late %d ms (state %s)", late, S.state))
            if late > 10000 and t - last_rescue > 120000 then
                last_rescue = t
                local ok_j, J = pcall(require, "k3aplayer_jit")
                if ok_j then
                    logger.warn("[K3APlayer]", J.summary())
                    logger.warn("[K3APlayer] low memory:", (J.map()))
                end
            end
        end
        last_beat = t
    end
    local e = readStatus()
    if e and current then
        local before = S.state
        local song = Music.songs()[current]
        -- the status belongs to the last requested song (not the previous one, while the engine switches)
        if song and e.mark == tostring(mark) and e.file == song.path then
            if e.state == "end" then
                if end_handled ~= mark then
                    end_handled = mark
                    errors_in_row = 0
                    S.pos = S.dur
                    Music.next(false)
                    Music.announce()
                end
            elseif e.state == "error" then
                if end_handled ~= mark then
                    end_handled = mark
                    errors_in_row = errors_in_row + 1
                    logger.warn("[K3APlayer] error:", e.error)
                    if errors_in_row < 3 and #Music.songs() > 1 then
                        Music.next(true)
                    else
                        S.state, S.error = "error", e.error
                        notify("state")
                    end
                end
            else
                errors_in_row = 0
                S.state, S.pos, S.dur, S.error = e.state, e.pos, e.dur, nil
                S.kbps = tonumber(e.kbps)
                if S.state ~= before then notify("state") else notify("pos") end
            end
        end
    end
    if Music.active() then
        local now = os.time()
        if S.state == "playing" then
            -- while playing, keep the Kindle (its own screensaver timer) and KOReader's
            -- autosuspend plugin awake
            if now - last_keepawake >= 240 then
                last_keepawake = now
                local powerd = Device:getPowerDevice()
                if Device:isKindle() and powerd.resetT1Timeout then pcall(powerd.resetT1Timeout, powerd) end
                local Event = require("ui/event")
                UIManager:broadcastEvent(Event:new("InputEvent"))
            end
            if now - last_saved >= 30 then
                last_saved = now
                Music.rememberPosition(true)
            end
        end
        UIManager:scheduleIn(1, heartbeat)
    else
        last_beat = nil
    end
end

--- When a song changes on its own: a short notice with the title, unless the player is on screen.
function Music.announce()
    local top = UIManager:getNthTopWidget()
    if top and top.name == "k3aplayer_player" then return end
    local c = Music.current()
    if not c or not Music.playing() then return end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = "\u{F001}  " .. T(_("Now playing: %1"), c.title), timeout = 3 })
end

return Music
