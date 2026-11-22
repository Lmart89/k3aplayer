--[[--
K3 Audio Player: audio engine. A separate process (not a KOReader module), started by
k3aplayer_music with KOReader's own luajit:

    <koreader>/luajit <plugin>/k3aplayer_engine.lua <work dir> <KOReader pid>

Plays through the Kindle's GStreamer 0.10 via LuaJIT FFI. MP3 uses its own pipeline
    fdsrc fd=N ! mfw_mp3decoder ! audioconvert ! audioresample ! volume ! alsasink
To seek it does not use GStreamer's seek (on the K3 a forward seek takes 7-9 s and blocks): it
closes the pipeline and opens a new one reading the file from the byte of the requested second
(k3aplayer_mp3: duration and bytes per second). Other formats: playbin with its own seek.
Tested on a Kindle 3: seeks of 120-170 ms, VBR and 320 kbps files.

Commands (one per line on the FIFO <work dir>/commands):
    play <path> | from <sec> <path> | pause | resume | toggle | stop
    seek <sec> | move <±sec> | vol <0-150> | mark <id> | status | quit
Status in <work dir>/status (key=value; every second and after each command):
    state=stopped|playing|paused|end|error, file, pos, dur, vol, error, kind, kbps, n, pid, mark
If KOReader goes away (closed or crashed), the engine quits by itself.
--]]--

local ffi = require("ffi")
local bit = require("bit")

-- the plugin modules (k3aplayer_mp3) live next to this file
local plugin_dir = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local Mp3 = require("k3aplayer_mp3")

ffi.cdef[[
typedef int gboolean;
typedef long long gint64;
typedef unsigned long long guint64;
typedef struct { unsigned int domain; int code; char *message; } GError;

void gst_init(int *argc, char ***argv);
void *gst_element_factory_make(const char *factory, const char *name);
void *gst_parse_launch(const char *pipeline_description, GError **error);
void *gst_bin_get_by_name(void *bin, const char *name);
int gst_element_set_state(void *element, int state);
int gst_element_get_state(void *element, int *state, int *pending, guint64 timeout);
gboolean gst_element_query_position(void *element, int *format, gint64 *cur);
gboolean gst_element_query_duration(void *element, int *format, gint64 *dur);
gboolean gst_element_seek_simple(void *element, int format, int flags, gint64 pos);
void *gst_pipeline_get_bus(void *pipeline);
void *gst_bus_pop(void *bus);
void *gst_bus_pop_filtered(void *bus, int types);
const void *gst_message_get_structure(void *message);
void gst_message_parse_error(void *message, GError **gerror, char **debug);
void gst_mini_object_unref(void *mini_object);
void gst_object_unref(void *object);

void g_object_set(void *object, const char *first_property_name, ...);
char *g_filename_to_uri(const char *filename, const char *hostname, GError **error);
void g_free(void *mem);
void g_error_free(GError *error);

struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
int open(const char *pathname, int flags, ...);
long read(int fd, void *buf, unsigned long count);
long lseek(int fd, long offset, int whence);
int close(int fd);
int mkfifo(const char *pathname, unsigned int mode);
int getpid(void);
int kill(int pid, int sig);
int setpriority(int which, int who, int prio);
struct k3ap_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int clk_id, struct k3ap_timespec *tp);
]]

local C = ffi.C

-- Slightly higher priority than KOReader (nice -5), set BEFORE GStreamer creates its threads, which
-- inherit it. Decoding barely uses CPU; if it has to wait for KOReader (a heavy repaint can hold the
-- CPU for seconds on the K3), the sound stutters and pause commands wait.
local PRIORITY = -5
if C.setpriority(0, 0, PRIORITY) ~= 0 then PRIORITY = 0 end

local gst = ffi.load("libgstreamer-0.10.so.0")
local gobject = ffi.load("libgobject-2.0.so.0")
local glib = ffi.load("libglib-2.0.so.0")

local ST_NULL, ST_PAUSED, ST_PLAYING = 1, 3, 4
local FMT_TIME = 3
local SEEK_FLUSH, SEEK_KEY_UNIT = 1, 4
local MSG_EOS, MSG_ERROR = 1, 2
local NS = 1000000000
local NULLP = ffi.cast("void *", nil)
local O_RDONLY, O_WRONLY, O_NONBLOCK = 0, 1, 2048
local POLLIN = 1

local dir = arg[1] or "/tmp/k3aplayer"
local parent_pid = tonumber(arg[2] or "")
os.execute("mkdir -p '" .. dir .. "'")
local FIFO_PATH = dir .. "/commands"
local STATUS_PATH = dir .. "/status"

local function log(...)
    io.stdout:write(os.date("%H:%M:%S "), table.concat({...}, " "), "\n")
    io.stdout:flush()
end

-- monotonic clock in ms (clock_gettime may live in librt with glibc 2.5)
local ts = ffi.new("struct k3ap_timespec")
local clock = C
if not pcall(function() return C.clock_gettime end) then
    local ok, rt = pcall(ffi.load, "librt.so.1")
    clock = ok and rt or nil
end
local function ms()
    if clock and clock.clock_gettime(1, ts) == 0 then
        return tonumber(ts.tv_sec) * 1000 + math.floor(tonumber(ts.tv_nsec) / 1000000)
    end
    return os.time() * 1000
end

local function slurp(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s
end

--- Diagnostics (every 60 s in the log): load, free memory, engine and KOReader memory.
local function diagnostics(state, koreader_pid)
    local load = slurp("/proc/loadavg"):match("^(%S+ %S+ %S+)") or "?"
    local mem = slurp("/proc/meminfo")
    local function kb(key) return tonumber(mem:match(key .. ":%s+(%d+)")) or 0 end
    local free = kb("MemFree") + kb("Buffers") + kb("Cached")
    local me = slurp("/proc/self/status")
    local ko = koreader_pid and slurp("/proc/" .. koreader_pid .. "/status") or ""
    log(string.format("diag: %s load %s · free %d MB · engine %s MB, %s threads · KOReader %s MB",
        state, load, math.floor(free / 1024),
        tostring(math.floor((tonumber(me:match("VmRSS:%s+(%d+)")) or 0) / 1024)), me:match("Threads:%s+(%d+)") or "?",
        tostring(math.floor((tonumber(ko:match("VmRSS:%s+(%d+)")) or 0) / 1024))))
end

---------------------------------------------------------------- status
local S = {
    state = "stopped", file = "", pos = 0, dur = 0, vol = 100,
    error = "", kind = "", kbps = 0, n = 0, pid = C.getpid(), mark = "",
}
-- mark: set by the plugin before each song ("mark <id>"), so it knows which request a status is for
local KEYS = { "state", "file", "pos", "dur", "vol", "error", "kind", "kbps", "n", "pid", "mark" }

local function writeStatus()
    S.n = S.n + 1
    local tmp = STATUS_PATH .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    for _, k in ipairs(KEYS) do
        local v = S[k]
        if k == "pos" or k == "dur" then v = string.format("%.1f", v) end
        f:write(k, "=", tostring(v), "\n")
    end
    f:close()
    os.rename(tmp, STATUS_PATH)
end

---------------------------------------------------------------- GStreamer
gst.gst_init(nil, nil)
local has_filtered = pcall(function() return gst.gst_bus_pop_filtered end)
log("engine started, pid", S.pid, "parent", tostring(parent_pid), "nice", PRIORITY)
diagnostics("start", parent_pid)

local P = nil      -- current pipeline { el, bus, vol, fd, base }
local info = nil   -- header of the current MP3
local stuck, last_pos = 0, -1 -- seconds in a row without the position moving (while playing)

local fmt = ffi.new("int[1]")
local val = ffi.new("gint64[1]")

local function destroy()
    if not P then return end
    gst.gst_element_set_state(P.el, ST_NULL)
    if P.vol ~= nil then gst.gst_object_unref(P.vol) end
    if P.bus ~= nil then gst.gst_object_unref(P.bus) end
    gst.gst_object_unref(P.el)
    if P.fd then C.close(P.fd) end
    P = nil
end

local function applyVolume()
    if not P then return end
    local target = P.vol ~= nil and P.vol or P.el
    gobject.g_object_set(target, "volume", ffi.cast("double", S.vol / 100), NULLP)
end

local function createMp3(from, gst_state)
    local offset = info.start + math.floor(math.max(0, from) * info.bps)
    local fd = C.open(S.file, O_RDONLY)
    if fd < 0 then return false, "cannot open the file" end
    if C.lseek(fd, offset, 0) < 0 then
        C.close(fd)
        return false, "cannot seek to byte " .. offset
    end
    local err = ffi.new("GError *[1]")
    local el = gst.gst_parse_launch(string.format(
        "fdsrc fd=%d ! mfw_mp3decoder ! audioconvert ! audioresample ! volume name=k3apvol ! alsasink", fd), err)
    if el == nil then
        local text = err[0] ~= nil and ffi.string(err[0].message) or "gst_parse_launch failed"
        if err[0] ~= nil then glib.g_error_free(err[0]) end
        C.close(fd)
        return false, text
    end
    P = { el = el, bus = gst.gst_pipeline_get_bus(el), vol = gst.gst_bin_get_by_name(el, "k3apvol"),
          fd = fd, base = from }
    applyVolume()
    if gst.gst_element_set_state(el, gst_state) == 0 then
        destroy()
        return false, "cannot start playback"
    end
    return true
end

local function createPlaybin(gst_state)
    local el = gst.gst_element_factory_make("playbin", nil)
    if el == nil then return false, "cannot create playbin" end
    local sink = gst.gst_element_factory_make("alsasink", nil)
    local vsink = gst.gst_element_factory_make("fakesink", nil)
    if sink ~= nil then gobject.g_object_set(el, "audio-sink", sink, NULLP) end
    if vsink ~= nil then gobject.g_object_set(el, "video-sink", vsink, NULLP) end
    local uri = glib.g_filename_to_uri(S.file, nil, nil)
    if uri == nil then
        gst.gst_object_unref(el)
        return false, "invalid path"
    end
    gobject.g_object_set(el, "uri", uri, NULLP)
    glib.g_free(uri)
    P = { el = el, bus = gst.gst_pipeline_get_bus(el), vol = nil, base = 0 }
    applyVolume()
    if gst.gst_element_set_state(el, gst_state) == 0 then
        destroy()
        return false, "cannot play"
    end
    return true
end

local function query()
    if not P then return end
    fmt[0] = FMT_TIME
    if gst.gst_element_query_position(P.el, fmt, val) ~= 0 then
        S.pos = P.base + tonumber(val[0]) / NS
    end
    if S.kind == "playbin" then
        fmt[0] = FMT_TIME
        if gst.gst_element_query_duration(P.el, fmt, val) ~= 0 then
            S.dur = tonumber(val[0]) / NS
        end
    end
end

local function fail(text)
    destroy()
    S.state, S.error = "error", text
    log(string.format("error: %s (in %s, %.1f s)", text, S.file, S.pos))
end

local function load(path, from)
    destroy()
    S.file, S.pos, S.dur, S.error, S.kbps = path, 0, 0, "", 0
    stuck, last_pos = 0, -1
    local f = io.open(path, "rb")
    if not f then return fail("file not found: " .. path) end
    f:close()
    from = from or 0
    local ok, reason
    info = nil
    if path:lower():match("%.mp3$") then
        info, reason = Mp3.parse(path)
        if info then
            S.kind, S.dur, S.kbps = "mp3", info.dur, info.kbps
            from = math.min(from, math.max(0, info.dur - 1))
            log(string.format("mp3: start %d, %.1f s, %d kbps%s", info.start, info.dur, info.kbps,
                info.vbr and " VBR" or ""))
            ok, reason = createMp3(from, ST_PLAYING)
        else
            log("MP3 header not recognized (" .. tostring(reason) .. "), using playbin")
        end
    end
    if not info then
        S.kind = "playbin"
        ok, reason = createPlaybin(from > 0 and ST_PAUSED or ST_PLAYING)
        if ok and from > 0 then
            local st = ffi.new("int[2]")
            gst.gst_element_get_state(P.el, st, st + 1, ffi.cast("guint64", 5 * NS))
            gst.gst_element_seek_simple(P.el, FMT_TIME, SEEK_FLUSH + SEEK_KEY_UNIT, ffi.cast("gint64", from * NS))
            gst.gst_element_set_state(P.el, ST_PLAYING)
        end
    end
    if not ok then return fail(reason) end
    S.state, S.pos = "playing", from
    log(string.format("play %s from %.1f (%s)", path, from, S.kind))
end

local function seek(sec)
    if S.state ~= "playing" and S.state ~= "paused" then return end
    if S.dur > 0 then sec = math.min(sec, S.dur - 1) end
    sec = math.max(0, sec)
    if S.kind == "mp3" and S.state == "paused" then
        S.pos = sec -- paused MP3 has no pipeline: "resume" starts there
        return
    end
    if not P then return end
    stuck, last_pos = 0, -1
    if S.kind == "mp3" then
        destroy()
        local ok, reason = createMp3(sec, S.state == "paused" and ST_PAUSED or ST_PLAYING)
        if not ok then return fail(reason) end
    else
        gst.gst_element_seek_simple(P.el, FMT_TIME, SEEK_FLUSH + SEEK_KEY_UNIT, ffi.cast("gint64", sec * NS))
    end
    S.pos = sec
end

---------------------------------------------------------------- bus
local function checkBus()
    while P do
        local msg
        if has_filtered then
            msg = gst.gst_bus_pop_filtered(P.bus, MSG_EOS + MSG_ERROR)
        else
            msg = gst.gst_bus_pop(P.bus) -- unfiltered: dropped; the end is detected from the position
        end
        if msg == nil then return end
        if has_filtered then
            if gst.gst_message_get_structure(msg) == nil then -- EOS has no structure
                gst.gst_mini_object_unref(msg)
                destroy()
                S.state, S.pos = "end", S.dur
                return
            end
            local err = ffi.new("GError *[1]")
            local dbg = ffi.new("char *[1]")
            gst.gst_message_parse_error(msg, err, dbg)
            local text = err[0] ~= nil and ffi.string(err[0].message) or "unknown error"
            if dbg[0] ~= nil then log("detail:", ffi.string(dbg[0])); glib.g_free(dbg[0]) end
            if err[0] ~= nil then glib.g_error_free(err[0]) end
            gst.gst_mini_object_unref(msg)
            return fail(text)
        end
        gst.gst_mini_object_unref(msg)
    end
end

---------------------------------------------------------------- commands
local running = true

local function execute(line)
    local cmd, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
    if not cmd then return end
    log("command:", line)
    if cmd == "play" then
        load(rest)
    elseif cmd == "from" then
        local s, path = rest:match("^(%S+)%s+(.+)$")
        load(path or "", tonumber(s))
    elseif cmd == "pause" then
        if P and S.state == "playing" then
            query()
            if S.kind == "mp3" then
                -- MP3: pausing closes the pipeline (and releases the audio device); "resume" reopens it
                -- at the same position, like a seek (~150 ms). Going to PAUSED could block for seconds.
                destroy()
            else
                gst.gst_element_set_state(P.el, ST_PAUSED)
            end
            S.state = "paused"
        end
    elseif cmd == "resume" then
        if S.state == "paused" then
            if S.kind == "mp3" and not P and info then
                local ok, reason = createMp3(S.pos, ST_PLAYING)
                if not ok then fail(reason) else S.state = "playing" end
            elseif P then
                gst.gst_element_set_state(P.el, ST_PLAYING)
                S.state = "playing"
            end
            stuck, last_pos = 0, -1
        end
    elseif cmd == "toggle" then
        return execute(S.state == "paused" and "resume" or "pause")
    elseif cmd == "stop" then
        destroy()
        S.state, S.pos = "stopped", 0
    elseif cmd == "seek" then
        seek(tonumber(rest) or 0)
    elseif cmd == "move" then
        seek(S.pos + (tonumber(rest) or 0))
    elseif cmd == "vol" then
        S.vol = math.max(0, math.min(150, tonumber(rest) or 100))
        applyVolume()
    elseif cmd == "mark" then
        S.mark = rest
    elseif cmd == "quit" then
        running = false
    elseif cmd ~= "status" then
        log("unknown command:", cmd)
    end
    writeStatus()
end

---------------------------------------------------------------- FIFO and main loop
C.mkfifo(FIFO_PATH, tonumber("666", 8)) -- fails harmlessly if it already exists
local fd = C.open(FIFO_PATH, O_RDONLY + O_NONBLOCK)
if fd < 0 then
    log("cannot open the FIFO", FIFO_PATH)
    os.exit(1)
end
-- a writer of our own, so the FIFO does not hit EOF between commands
local fd_w = C.open(FIFO_PATH, O_WRONLY + O_NONBLOCK)

writeStatus()
log("listening for commands on", FIFO_PATH)

local pfd = ffi.new("struct pollfd[1]")
local buf = ffi.new("char[512]")
local pending = ""
local last_sec = os.time()
local turn = ms()

while running do
    -- the loop waits 250 ms at most: if it takes much longer, something else holds the CPU
    local now_ms = ms()
    if now_ms - turn > 1500 then log(string.format("engine held up %d ms", now_ms - turn)) end
    turn = now_ms
    pfd[0].fd, pfd[0].events, pfd[0].revents = fd, POLLIN, 0
    if C.poll(pfd, 1, 250) > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0 then
        local n = C.read(fd, buf, 512)
        if n > 0 then
            pending = pending .. ffi.string(buf, n)
            for line in pending:gmatch("([^\n]*)\n") do
                execute(line)
                if not running then break end
            end
            pending = pending:match("[^\n]*$")
        end
    end
    checkBus()
    local now = os.time()
    if now ~= last_sec then
        last_sec = now
        if S.state == "playing" then
            query()
            if not has_filtered and S.dur > 0 and S.pos >= S.dur - 0.5 then
                destroy()
                S.state, S.pos = "end", S.dur
            end
            -- playing but not moving (the audio ran dry and GStreamer does not recover):
            -- reopen at the same spot
            if S.state == "playing" and P then
                if S.pos <= last_pos + 0.05 then stuck = stuck + 1 else stuck = 0 end
                last_pos = S.pos
                if stuck >= 4 and S.kind == "mp3" then
                    log(string.format("stuck at %.1f s: reopening there", S.pos))
                    stuck, last_pos = 0, -1
                    seek(S.pos)
                end
            end
        else
            stuck, last_pos = 0, -1
        end
        writeStatus()
        if now % 60 == 0 then diagnostics(string.format("%s %.0f s", S.state, S.pos), parent_pid) end
        -- KOReader is gone (closed or crashed): do not keep playing on our own
        if parent_pid and now % 5 == 0 and C.kill(parent_pid, 0) ~= 0 then
            log("KOReader exited: the engine quits")
            running = false
        end
    end
end

destroy()
C.close(fd)
if fd_w >= 0 then C.close(fd_w) end
S.state = "closed"
writeStatus()
log("engine closed")
