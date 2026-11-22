--[[--
K3 Audio Player: protects LuaJIT's machine-code area on the Kindle 3.

On the K3 KOReader paints everything in Lua (there is no C blitter), so painting depends on LuaJIT
compiling the drawing loops. On ARM, LuaJIT can only place its compiled code ("mcode") a few MB
away from the executable (ARM branches cannot reach further), and KOReader's luajit executable sits
at 0x10000: the C heap (brk) starts right behind it and grows with dictionaries, sqlite, crengine…
Once the heap fills that window and LuaJIT needs new memory, it cannot find any ("failed to
allocate mcode memory"): it stops compiling and every repaint goes from ~1 s to ~30 s, for good.

Remedy: a "fence" (64 KB with no permissions) is mapped a little above the end of the heap. brk
cannot grow past an occupied mapping; glibc then falls back to mmap, which uses high addresses. The
gap between the fence and the JIT limit stays free for compiled code.

Only applied on ARM Linux (the K3), once, when the player is first opened. It also counts aborted
traces and flushes, for the log.
]]

local logger = require("logger")

local M = {}

local ffi_ok, ffi = pcall(require, "ffi")
local count = { ok = 0, aborted = 0, flushes = 0, reasons = {} }
local fence = nil       -- fence address (number), if mapped
local prepared = false

-- reach of a JIT branch on ARM: LJ_TARGET_JUMPRANGE 25 → ±(16 MB − 2 MB)
local REACH = 14 * 1024 * 1024
local FENCE = 64 * 1024
local MARGIN = 1024 * 1024  -- how much the heap can still grow with brk before the fence

local function hex(n) return n and string.format("0x%x", n) or "?" end

--- Low memory mappings (executable, heap, JIT code…) from /proc/self/maps.
-- Returns the list {from, to, perm, name} and the end of [heap].
local function lowMappings(limit)
    local f = io.open("/proc/self/maps", "r")
    if not f then return {}, nil end
    local maps, heap_end = {}, nil
    for line in f:lines() do
        local a, b, perm, rest = line:match("^(%x+)%-(%x+)%s+(%S+)%s+%S+%s+%S+%s+%S+%s*(.*)$")
        if a then
            local from, to = tonumber(a, 16), tonumber(b, 16)
            if rest == "[heap]" then heap_end = to end
            if from < limit then
                maps[#maps + 1] = { from = from, to = to, perm = perm, name = rest }
            end
        end
    end
    f:close()
    return maps, heap_end
end

--- One line with the low memory map, for the log.
function M.map()
    local maps, heap_end = lowMappings(0x02000000)
    local parts = {}
    for _, z in ipairs(maps) do
        local name = z.name ~= "" and z.name:match("[^/]+$") or "anon"
        parts[#parts + 1] = string.format("%s-%s %s %s", hex(z.from), hex(z.to), z.perm, name)
    end
    return table.concat(parts, " | "), heap_end
end

local function onEvent(what, _tr, _func, _pc, otr, _oex)
    if what == "stop" then
        count.ok = count.ok + 1
    elseif what == "abort" then
        count.aborted = count.aborted + 1
        local key = tostring(otr)
        count.reasons[key] = (count.reasons[key] or 0) + 1
    elseif what == "flush" then
        count.flushes = count.flushes + 1
    end
end

--- Summary of JIT activity since the last summary (and resets it).
function M.summary()
    local vmdef_ok, vmdef = pcall(require, "jit.vmdef")
    local reasons = {}
    for key, n in pairs(count.reasons) do
        local text = key
        local num = tonumber(key)
        if vmdef_ok and vmdef.traceerr and num and vmdef.traceerr[num] then
            text = vmdef.traceerr[num]:gsub("%%%a", "…")
        end
        reasons[#reasons + 1] = n .. "× " .. text
    end
    table.sort(reasons)
    local on = jit and jit.status() and "on" or "OFF"
    local s = string.format("JIT %s: %d new traces, %d aborted%s, %d flushes",
        on, count.ok, count.aborted,
        #reasons > 0 and (" (" .. table.concat(reasons, "; ") .. ")") or "", count.flushes)
    count.ok, count.aborted, count.flushes, count.reasons = 0, 0, 0, {}
    return s
end

--- Maps the fence above the heap and starts counting. Called once.
function M.prepare()
    if prepared or not jit or not ffi_ok or jit.arch ~= "arm" or ffi.os ~= "Linux" then return end
    prepared = true
    -- compiled code: up to 2 MB (default 512 KB) and more traces before a full flush; every flush
    -- forces painting to be recompiled and to ask for new memory, which is the delicate part here
    pcall(jit.opt.start, "maxmcode=2048", "maxtrace=2000")
    pcall(jit.attach, onEvent, "trace")

    local _, heap_end = lowMappings(0x02000000)
    if not heap_end then
        logger.warn("[K3APlayer] JIT: no [heap] in /proc/self/maps; no fence")
        return
    end
    local limit = 0x10000 + REACH
    local where = math.floor((heap_end + MARGIN) / 0x10000 + 1) * 0x10000
    if where + FENCE + 1024 * 1024 > limit then
        logger.warn("[K3APlayer] JIT: the heap already reaches", hex(heap_end), "; no room for the fence")
        return
    end
    pcall(ffi.cdef, "void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);")
    pcall(ffi.cdef, "int munmap(void *addr, size_t len);")
    -- PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE (ARM Linux); the address is only a hint
    local ok, p = pcall(function()
        return ffi.C.mmap(ffi.cast("void *", where), FENCE, 0, 0x02 + 0x20 + 0x4000, -1, 0)
    end)
    if not ok then
        logger.warn("[K3APlayer] JIT: mmap failed:", tostring(p))
        return
    end
    local addr = tonumber(ffi.cast("uintptr_t", p))
    if addr == where then
        fence = addr
        logger.info("[K3APlayer] JIT: fence at", hex(fence), "(heap up to", hex(heap_end) .. ")")
    else
        if addr ~= 0xffffffff then pcall(ffi.C.munmap, p, FENCE) end
        logger.warn("[K3APlayer] JIT: the fence landed at", hex(addr), "instead of", hex(where), "; removed")
    end
    logger.info("[K3APlayer] JIT: low memory:", (M.map()))
end

function M.fence() return fence end

return M
