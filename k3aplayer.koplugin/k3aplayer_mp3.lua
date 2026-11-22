--[[--
MP3 header reader: where the audio starts, how long it lasts and how many bytes per second it has.
Used by the audio engine (to seek by reopening the file at the exact byte) and by the song list
(durations). No dependencies: it also runs inside the engine, outside KOReader.

    local Mp3 = require("k3aplayer_mp3")
    local info = Mp3.parse("/mnt/us/music/x.mp3")
    -- info = { start, dur, bps, kbps, vbr } or nil, reason

Duration: the frame count of the Xing/Info or VBRI header when there is one; otherwise constant
bitrate (audio bytes × 8 / kbps). Skips a leading ID3v2 tag and discounts a trailing ID3v1 tag.
--]]--

local bit = require("bit")

local Mp3 = {}

local BITRATES = {
    [1] = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }, -- MPEG1 layer III
    [2] = { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },     -- MPEG2/2.5 layer III
}
local SAMPLE_RATES = { [3] = { 44100, 48000, 32000 }, [2] = { 22050, 24000, 16000 }, [0] = { 11025, 12000, 8000 } }

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function Mp3.parse(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local size = f:seek("end")
    f:seek("set", 0)
    local head = f:read(10) or ""
    local start = 0
    if head:sub(1, 3) == "ID3" and #head == 10 then
        local a, b, c, d = head:byte(7, 10)
        start = ((a * 128 + b) * 128 + c) * 128 + d + 10
        if bit.band(head:byte(6), 0x10) ~= 0 then start = start + 10 end
    end
    f:seek("set", start)
    local block = f:read(65536) or ""
    local stop = size
    if size > 128 then
        f:seek("end", -128)
        if (f:read(3) or "") == "TAG" then stop = size - 128 end
    end
    f:close()

    for i = 1, #block - 200 do
        local b1, b2, b3, b4 = block:byte(i, i + 3)
        if b1 == 0xFF and bit.band(b2, 0xE0) == 0xE0 then
            local ver = bit.band(bit.rshift(b2, 3), 3)        -- 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
            local layer = bit.band(bit.rshift(b2, 1), 3)      -- 1 = layer III
            local ibr = bit.rshift(b3, 4)
            local isr = bit.band(bit.rshift(b3, 2), 3)
            if ver ~= 1 and layer == 1 and ibr > 0 and ibr < 15 and isr < 3 then
                local kbps = BITRATES[ver == 3 and 1 or 2][ibr]
                local sr = SAMPLE_RATES[ver][isr + 1]
                local spf = ver == 3 and 1152 or 576
                local mono = bit.rshift(b4, 6) == 3
                local side = ver == 3 and (mono and 17 or 32) or (mono and 9 or 17)
                local x = i + 4 + side
                local tag = block:sub(x, x + 3)
                local data = stop - (start + i - 1)
                local dur, vbr
                if tag == "Xing" or tag == "Info" then
                    local flags = be32(block, x + 4)
                    if bit.band(flags, 1) ~= 0 then
                        dur = be32(block, x + 8) * spf / sr
                        vbr = tag == "Xing"
                    end
                elseif block:sub(i + 36, i + 39) == "VBRI" then
                    dur = be32(block, i + 36 + 14) * spf / sr
                    vbr = true
                end
                if not dur or dur <= 0 then
                    dur = data * 8 / (kbps * 1000)
                    vbr = false
                end
                return {
                    start = start + i - 1, dur = dur, bps = data / dur,
                    kbps = math.floor(data * 8 / dur / 1000 + 0.5), vbr = vbr,
                }
            end
        end
    end
    return nil, "no MP3 frame found"
end

--- "2:41", "1:02:05".
function Mp3.time(sec)
    sec = math.max(0, math.floor((sec or 0) + 0.5))
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

return Mp3
