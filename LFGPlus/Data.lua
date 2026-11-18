-- Endorsement data for tooltips, from the separate load-on-demand data add-on, in
-- format 0 (a plain table) or format 3 (packed, in chunks). Each player has four counts, one per tag, in tag order:
-- Fun, Skilled, Helpful, Leader.
--
-- LFG+ ships in two parts: this add-on, and LFGPlus_Data_<Version>_<Region>, rebuilt every night. At login we load the
-- data add-on for our game version and region; it calls LFGPlus_RegisterData once per file. With no data, tooltips add
-- nothing (better than "No endorsements yet" for everyone) and /lfgplus says where to get it.

local _, ns = ...

local SUPPORTED_FORMATS = { [0] = true, [3] = true }
local BLOCK_SIZE = 64
local MAX_CHUNKS = 4096
local floor, byte, sort = math.floor, string.byte, table.sort
local VERSION_FOLDERS = { [10] = "Retail", [20] = "Classic", [30] = "ClassicEra", [40] = "Forever", [50] = "Anniversary" }
local REGION_FOLDERS = { [1] = "US", [2] = "EU", [3] = "KR", [4] = "TW" }
local OLD_DATA_DAYS = 7          -- from this age on, /lfgplus and the login say the data is old

ns.data = nil                    -- format 0: { ..., entries = { [key] = { fun, skilled, helpful, leader } } }; format 3: { ..., parts = { [chunk] = its fields } }
ns.dataStatus = { state = "not loaded" }
local arriving = nil             -- format 3: the chunks registered so far, until all of them are here
local refused = false            -- format 3: a mixed or repeated chunk arrived, so this session has no data

--- The data add-on's folder name for a game version and region, or nil.
function ns.DataAddonName(gameVersion, region)
    local version, regionName = VERSION_FOLDERS[gameVersion or 0], REGION_FOLDERS[region or 0]
    if not version or not regionName then return nil end
    return ("LFGPlus_Data_%s_%s"):format(version, regionName)
end

local function wholeNumber(value, low, high)
    return type(value) == "number" and value >= low and value <= high and value == floor(value)
end

--- True when the data carries what its format needs: format 3 a palette per tag.
local function wellFormed(data)
    if data.format == 3 then
        local p = data.palettes
        return type(data.data) == "string" and type(data.index) == "table" and type(p) == "table"
            and type(p[1]) == "table" and type(p[2]) == "table" and type(p[3]) == "table" and type(p[4]) == "table"
            and type(data.k) == "number" and type(data.entries) == "number" and type(data.players) == "number"
    end
    return type(data.entries) == "table"
end

--- Why a format-3 chunk's own numbers can't be used, or nil.
local function badChunk(data)
    if not wholeNumber(data.bits, 40, 52) then return "a fingerprint of " .. tostring(data.bits) .. " bits" end
    local half = wholeNumber(data.chunks, 1, MAX_CHUNKS) and data.chunks or 0
    while half > 1 and half % 2 == 0 do half = half / 2 end -- a power of two halves down to 1
    if half ~= 1 then return tostring(data.chunks) .. " data files" end
    if not wholeNumber(data.chunk, 0, data.chunks - 1) then return "data file " .. tostring(data.chunk) .. " of " .. data.chunks end
    return nil
end

--- Drops every chunk and refuses the rest of this session's: files from two downloads must never be mixed.
local function refuseChunks(reason)
    arriving, refused, ns.data = nil, true, nil
    ns.dataStatus = { state = "mixed", reason = reason }
    ns.Log.Warn("data", "ignored the data add-on: %s. Install it again.", reason)
    return false
end

--- One chunk of a format-3 data add-on. The data is loaded once every chunk has registered.
local function registerChunk(data)
    if refused then return false end
    local bad = badChunk(data)
    if bad then
        ns.dataStatus = { state = "unsupported", reason = bad }
        ns.Log.Warn("data", "ignored a data file with %s", bad)
        return false
    end
    arriving = arriving or { format = 3, day = data.day, bits = data.bits, chunks = data.chunks, parts = {}, count = 0, players = 0, cache = {} }
    local set = arriving
    if data.day ~= set.day or data.bits ~= set.bits or data.chunks ~= set.chunks then return refuseChunks("files from different days") end
    if set.parts[data.chunk] then return refuseChunks("data file " .. data.chunk .. " arrived twice") end
    set.parts[data.chunk] = data
    set.count, set.players = set.count + 1, set.players + data.players
    if set.count < set.chunks then
        ns.dataStatus = { state = "incomplete", reason = ("%d of %d data files loaded"):format(set.count, set.chunks) }
        return true
    end
    arriving, ns.data = nil, set
    ns.dataStatus = { state = "loaded", day = set.day, players = set.players }
    ns.Log.Info("data", "loaded data from %s: %s players in %d files, format 3", tostring(set.day), tostring(set.players), set.chunks)
    return true
end

--- Called by the data add-on: once by format 0's Data.lua, once per file by format 3's. Refuses unknown formats and
-- data for another version or region.
function LFGPlus_RegisterData(data)
    if type(data) ~= "table" or (SUPPORTED_FORMATS[data.format] and not wellFormed(data)) then
        ns.Log.Error("data", "the data add-on sent no entries")
        return false
    end
    if not SUPPORTED_FORMATS[data.format] then
        ns.dataStatus = { state = "unsupported", reason = "format " .. tostring(data.format) }
        ns.Log.Warn("data", "data format %s isn't supported by this version of LFG+; update the add-on", tostring(data.format))
        return false
    end
    if (ns.gameVersion and data.gameVersion ~= ns.gameVersion) or (ns.RegionId() and data.region ~= ns.RegionId()) then
        ns.dataStatus = { state = "mismatch", reason = ("data for version %s region %s"):format(tostring(data.gameVersion), tostring(data.region)) }
        ns.Log.Warn("data", "ignored %s", ns.dataStatus.reason)
        return false
    end
    if data.format == 3 then return registerChunk(data) end
    ns.data = data
    ns.dataStatus = { state = "loaded", day = data.day, players = data.players }
    ns.Log.Info("data", "loaded data from %s: %s players, format %s", tostring(data.day), tostring(data.players), tostring(data.format))
    return true
end

local function loadAddOn(name)
    if C_AddOns and C_AddOns.LoadAddOn then return C_AddOns.LoadAddOn(name) end
    if LoadAddOn then return LoadAddOn(name) end
    return false, "NO_API"
end

--- Loads the data add-on for this client. Called at PLAYER_LOGIN, once the game version and region are known.
function ns.LoadDataAddon()
    local name = ns.DataAddonName(ns.gameVersion, ns.RegionId())
    if not name then
        ns.dataStatus = { state = "unsupported", reason = "no data for this game version or region" }
        ns.Log.Info("data", "no data add-on for game version %s, region %s", tostring(ns.gameVersion), tostring(ns.RegionId()))
        return
    end
    if ns.data then return end
    local loaded, reason = loadAddOn(name)
    ns.Log.Info("data", "LoadAddOn(%s): %s %s", name, tostring(loaded), tostring(reason or ""))
    if not loaded then
        ns.dataStatus = { state = "missing", name = name, reason = tostring(reason) }
    elseif not ns.data and ns.dataStatus.state == "not loaded" then
        ns.dataStatus = { state = "empty", name = name }
        ns.Log.Warn("data", "%s loaded but registered no data", name)
    elseif arriving then
        -- Every file in the TOC has run, and some chunks never came: a broken install.
        ns.Log.Warn("data", "%s is incomplete: %s. Install it again.", name, ns.dataStatus.reason)
        arriving = nil
    end
end

--- Days since 1970-01-01 for a "YYYY-MM-DD" day (the data file's `day`, UTC), or nil when it isn't one.
function ns.DayNumber(day)
    local y, m, d = tostring(day):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    -- Howard Hinnant's days_from_civil, with March as the first month so the leap day ends the year.
    y = y - (m <= 2 and 1 or 0)
    local era = floor(y / 400)
    local yoe = y - era * 400
    local doy = floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
    return era * 146097 + yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy - 719468
end

--- "LFG+ data is 9 days old. Get the latest from lfg.plus/addon." once the loaded data is OLD_DATA_DAYS or more days
-- old at `now`; nil before that, or with no data. The data still shows either way.
function ns.OldDataNote(now)
    local day = ns.data and ns.DayNumber(ns.data.day)
    if not day then return nil end
    local age = floor(now / 86400) - day
    if age < OLD_DATA_DAYS then return nil end
    return ("LFG+ data is %d days old. Get the latest from lfg.plus/addon."):format(age)
end

-- What to do about each reason LoadAddOn gives for not loading the data add-on ("MISSING" and anything unknown aside).
local LOAD_FAILURES = {
    DISABLED = "%s is turned off. Turn it on in the AddOns list (at character select), then log in again.",
    INTERFACE_VERSION = "%s is out of date. Get the latest from lfg.plus/addon, CurseForge or Wago.",
}

--- One status line for /lfgplus. Given `now`, it also says when the data is old.
function ns.DataStatusLine(now)
    local s = ns.dataStatus
    if s.state == "loaded" then
        local line = ("Data: %s players, from %s."):format(tostring(s.players), tostring(s.day))
        local note = now and ns.OldDataNote(now)
        return note and (line .. " " .. note) or line
    elseif s.state == "missing" then
        local name = s.name or "the data add-on"
        if s.reason == "MISSING" then
            return ("Data: not installed. Get %s from lfg.plus/addon, CurseForge or Wago."):format(name)
        elseif LOAD_FAILURES[s.reason] then
            return "Data: " .. LOAD_FAILURES[s.reason]:format(name)
        end
        return ("Data: %s couldn't be loaded (%s). Install it again from lfg.plus/addon."):format(name, tostring(s.reason))
    end
    return "Data: none (" .. tostring(s.reason or s.state) .. ")."
end

-- ─── Format 3 ──────────────────────────────────────────────────────────────────────────────────────────────

--- A key's fingerprint: the top `bits` bits (40 to 52) of its SHA-256, from the first six bytes and part of the
-- seventh, so every step stays exact in a Lua number.
function ns.Fingerprint(key, bits)
    local b1, b2, b3, b4, b5, b6, b7 = byte(ns.Sha256(key), 1, 7)
    local first48 = ((((b1 * 256 + b2) * 256 + b3) * 256 + b4) * 256 + b5) * 256 + b6
    if bits <= 48 then return floor(first48 / 2 ^ (48 - bits)) end
    return first48 * 2 ^ (bits - 48) + floor(b7 / 2 ^ (56 - bits))
end

--- The bit at `pos` (from 0), most significant bit first. Past the end reads 0, so corrupt data ends a search, never a script.
local function bitAt(data, pos)
    return floor((byte(data, floor(pos / 8) + 1) or 0) / 2 ^ (7 - pos % 8)) % 2
end

--- Canonical Huffman decoding table for one tag's palette { count, length, ... }: [length .. ":" .. code] -> count.
local function decoder(palette)
    local order = {}
    for s = 1, #palette / 2 do order[s] = s end
    sort(order, function(a, b)
        local la, lb = palette[a * 2], palette[b * 2]
        if la ~= lb then return la < lb end
        return a < b
    end)
    local byCode, maxLen, code, previous = {}, 0, 0, nil
    for _, s in ipairs(order) do
        local length = palette[s * 2]
        if previous then code = (code + 1) * 2 ^ (length - previous) end
        previous = length
        byCode[length .. ":" .. code] = palette[s * 2 - 1]
        if length > maxLen then maxLen = length end
    end
    return { byCode = byCode, maxLen = maxLen }
end

--- Looks a key up in one chunk, given its fingerprint: exceptions, then the block that can hold the fingerprint.
-- Returns the four counts { fun, skilled, helpful, leader }, or nil.
function ns.PackedLookup(d, key, fp)
    local exception = d.exceptions and d.exceptions[key]
    if exception ~= nil then
        return exception or nil
    end
    local index = d.index
    local lo, hi, block = 1, #index / 2, nil
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        if index[mid * 2 - 1] <= fp then block, lo = mid, mid + 1 else hi = mid - 1 end
    end
    if not block then return nil end

    d.decoders = d.decoders or { decoder(d.palettes[1]), decoder(d.palettes[2]), decoder(d.palettes[3]), decoder(d.palettes[4]) }
    local decoders, data, k = d.decoders, d.data, d.k
    local pos, current = index[block * 2], index[block * 2 - 1]
    for i = 1, math.min(BLOCK_SIZE, d.entries - (block - 1) * BLOCK_SIZE) do
        if i > 1 then
            local q = 0
            while bitAt(data, pos) == 1 do q, pos = q + 1, pos + 1 end
            local r = 0
            for _ = 1, k + 1 do r, pos = r * 2 + bitAt(data, pos), pos + 1 end -- the unary's 0, then k bits
            current = current + q * 2 ^ k + r
        end
        local counts = {}
        for t = 1, 4 do
            local byCode, code, count = decoders[t].byCode, 0, nil
            for length = 1, decoders[t].maxLen do
                code, pos = code * 2 + bitAt(data, pos), pos + 1
                count = byCode[length .. ":" .. code]
                if count then break end
            end
            if not count then return nil end -- not a code: corrupt data
            counts[t] = count
        end
        if current == fp then return counts end
        if current > fp then return nil end
    end
    return nil
end

--- Looks a key up in format-3 data: the chunk its fingerprint belongs to, then that chunk. Returns the four counts or nil.
function ns.ChunkedLookup(set, key)
    local fp = ns.Fingerprint(key, set.bits)
    return ns.PackedLookup(set.parts[floor(fp / (2 ^ set.bits / set.chunks))], key, fp)
end

--- Looks up a character identity (Identity.lua). Returns its four counts { fun, skilled, helpful, leader }, or nil
-- when there's nothing to show. Packed lookups hash the key, so their answers are remembered for the session.
function ns.LookupCharacter(identity)
    if not identity or not ns.data then return nil end
    local entry
    if ns.data.format == 3 then
        entry = ns.data.cache[identity.key]
        if entry == nil then
            entry = ns.ChunkedLookup(ns.data, identity.key) or false
            ns.data.cache[identity.key] = entry
        end
    else
        entry = ns.data.entries[identity.key]
    end
    return entry or nil
end

--- True when tooltips have data to show (otherwise they add no line).
function ns.HasData()
    return ns.data ~= nil
end
