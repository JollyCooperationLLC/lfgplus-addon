-- Endorsement record v1, byte for byte the same as the site's and
-- proven against test/test-vectors/record-v1.json. Pure functions over byte strings.
--
-- Shapes:
--   character = { name = "First Surname", realm = "" (Forever) or "Realm", guid = "Player-..." or nil }
--   request   = { gameVersion, region, keyVersion, endorserAccount (32 hex), counter, endorsedAt, locationKind,
--                 locationId, endorser = character, endorsee = character }
--   ack       = { ackKeyVersion, ackLocationKind, ackLocationId, ackMac (8 bytes) }

local _, ns = ...

local byte, char, sub = string.byte, string.char, string.sub
local floor = math.floor

local RECORD_VERSION = 1
local MAX_NAME_BYTES = 64
local ACK_LABEL = "lfgplus/ack/v1"
local RECORD_LABEL = "lfgplus/record/v1"
ns.RECORD_TEXT_PREFIX = "LFGR1:"
ns.UNPROVEN_ACK = { ackKeyVersion = 0, ackLocationKind = 0, ackLocationId = 0, ackMac = string.rep("\0", 8) }

-- Endorsement tags: one bit each, the same numbers as the site's (labels in Format.lua). A
-- record's tags byte is a bit field; today it holds exactly one tag, so these are the only values it may take.
local SINGLE_TAGS = { [1] = true, [2] = true, [4] = true, [8] = true }

--- True for a bit field holding exactly one known tag: the only kind of endorsement allowed today.
function ns.IsSingleTag(bits)
    return SINGLE_TAGS[bits] == true
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

--- Bytes to base64url without padding (the encoder half of SetupCode.lua's FromBase64Url).
function ns.ToBase64Url(bytes)
    local out = {}
    for i = 1, #bytes, 3 do
        local b0, b1, b2 = byte(bytes, i, i + 2)
        local n = b0 * 65536 + (b1 or 0) * 256 + (b2 or 0)
        local c0, c1 = floor(n / 262144) % 64, floor(n / 4096) % 64
        local c2, c3 = floor(n / 64) % 64, n % 64
        out[#out + 1] = sub(ALPHABET, c0 + 1, c0 + 1) .. sub(ALPHABET, c1 + 1, c1 + 1)
        if b1 then out[#out + 1] = sub(ALPHABET, c2 + 1, c2 + 1) end
        if b2 then out[#out + 1] = sub(ALPHABET, c3 + 1, c3 + 1) end
    end
    return table.concat(out)
end

local function uint(value, size)
    if type(value) ~= "number" or value ~= floor(value) or value < 0 or value >= 256 ^ size then
        error("integer out of range", 0)
    end
    local out = {}
    for i = size - 1, 0, -1 do out[#out + 1] = char(floor(value / 256 ^ i) % 256) end
    return table.concat(out)
end

local function str8(text, what)
    text = tostring(text or "")
    if #text > MAX_NAME_BYTES then error(what .. " longer than " .. MAX_NAME_BYTES .. " bytes", 0) end
    return char(#text) .. text
end

local function isPrintableAscii(text)
    return #text > 0 and not text:find("[^\32-\126]")
end

--- Strict UTF-8: no overlong forms, surrogates or values past U+10FFFF (the same rule as TextDecoder's fatal mode).
local function isUtf8(text)
    local i, n = 1, #text
    while i <= n do
        local c = byte(text, i)
        local extra, min
        if c < 0x80 then extra = 0
        elseif c >= 0xC2 and c <= 0xDF then extra, min = 1, 0x80
        elseif c >= 0xE0 and c <= 0xEF then extra, min = 2, 0x800
        elseif c >= 0xF0 and c <= 0xF4 then extra, min = 3, 0x10000
        else return false end
        if extra > 0 then
            if i + extra > n then return false end
            local cp = c % (2 ^ (6 - extra))
            for k = 1, extra do
                local cc = byte(text, i + k)
                if cc < 0x80 or cc > 0xBF then return false end
                cp = cp * 64 + (cc - 0x80)
            end
            if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return false end
        end
        i = i + extra + 1
    end
    return true
end

local function compactGuid(guid)
    local server, uid = guid:match("^Player%-(%d+)%-(%x%x%x%x%x%x%x%x)$")
    if not server or uid:upper() ~= uid then return nil end
    if #server > 1 and sub(server, 1, 1) == "0" then return nil end -- one spelling only: no leading zeros
    if #server > 10 then return nil end
    local s = tonumber(server)
    if s > 4294967295 then return nil end
    return s, tonumber(uid, 16)
end

local function character(c, who)
    if type(c) ~= "table" or not c.name or c.name == "" then error(who .. " name is empty", 0) end
    local out = str8(c.name, who .. " name") .. str8(c.realm or "", who .. " realm")
    if c.guid == nil then return out .. "\2" end
    local server, uid = compactGuid(c.guid)
    if server then return out .. "\1" .. uint(server, 4) .. uint(uid, 4) end
    if not isPrintableAscii(c.guid) then error(who .. " guid must be printable ASCII", 0) end
    return out .. "\0" .. str8(c.guid, who .. " guid")
end

--- The request bytes, or nil and a reason (a field out of range, a name over 64 bytes).
function ns.EncodeRequest(req)
    local ok, bytes = pcall(function()
        local account = ns.FromHex(req.endorserAccount)
        if not account or #account ~= 16 or req.endorserAccount:find("%u") then error("malformed endorser account", 0) end
        if (req.keyVersion or 0) < 1 then error("keyVersion out of range", 0) end
        return uint(RECORD_VERSION, 1) .. uint(req.gameVersion, 1) .. uint(req.region, 1) .. uint(req.keyVersion, 2)
            .. account .. uint(req.counter, 4) .. uint(req.endorsedAt, 4) .. uint(req.locationKind, 1)
            .. uint(req.locationId, 4) .. character(req.endorser, "endorser") .. character(req.endorsee, "endorsee")
    end)
    if ok then return bytes end
    return nil, bytes
end

function ns.EncodeAck(ack)
    return uint(ack.ackKeyVersion, 2) .. uint(ack.ackLocationKind, 1) .. uint(ack.ackLocationId, 4) .. ack.ackMac
end

--- The endorsee's 8-byte ack MAC over a request and its own observed location.
function ns.AckMac(ackKey, requestBytes, ackLocationKind, ackLocationId)
    local signed = ACK_LABEL .. requestBytes .. uint(ackLocationKind, 1) .. uint(ackLocationId, 4)
    return sub(ns.HmacSha256(ackKey, signed), 1, 8)
end

--- The finished record: request ‖ ack ‖ tags ‖ 12-byte MAC by the real or drop key. Errors unless `tags`
-- holds exactly one tag.
function ns.EncodeRecord(requestBytes, ack, tags, signingKey)
    if not ns.IsSingleTag(tags) then error("tags must hold exactly one tag", 2) end
    local signed = requestBytes .. ns.EncodeAck(ack) .. uint(tags, 1)
    return signed .. sub(ns.HmacSha256(signingKey, RECORD_LABEL .. signed), 1, 12)
end

-- A tiny reader over a byte string. Every read errors on short input; decoders catch that and return nil.
local function reader(bytes)
    local r = { pos = 1 }
    function r.uint(size)
        if r.pos + size - 1 > #bytes then error("short", 0) end
        local v = 0
        for i = 0, size - 1 do v = v * 256 + byte(bytes, r.pos + i) end
        r.pos = r.pos + size
        return v
    end
    function r.raw(size)
        if r.pos + size - 1 > #bytes then error("short", 0) end
        local s = sub(bytes, r.pos, r.pos + size - 1)
        r.pos = r.pos + size
        return s
    end
    function r.str8()
        local length = r.uint(1)
        if length > MAX_NAME_BYTES then error("long", 0) end
        local s = r.raw(length)
        if not isUtf8(s) then error("utf8", 0) end
        return s
    end
    function r.remaining() return #bytes - r.pos + 1 end
    return r
end

local function readCharacter(r)
    local name = r.str8()
    if name == "" then error("empty name", 0) end
    local realm = r.str8()
    local kind = r.uint(1)
    if kind == 2 then return { name = name, realm = realm } end
    if kind == 1 then
        local server, uid = r.uint(4), r.uint(4)
        return { name = name, realm = realm, guid = ("Player-%d-%08X"):format(server, uid) }
    end
    if kind == 0 then
        local guid = r.str8()
        if not isPrintableAscii(guid) or compactGuid(guid) then error("guid", 0) end
        return { name = name, realm = realm, guid = guid }
    end
    error("guid kind", 0)
end

local function readRequest(r)
    if r.uint(1) ~= RECORD_VERSION then error("version", 0) end
    local req = {}
    req.gameVersion = r.uint(1)
    req.region = r.uint(1)
    req.keyVersion = r.uint(2)
    if req.keyVersion == 0 then error("keyVersion", 0) end
    req.endorserAccount = ns.ToHex(r.raw(16))
    req.counter = r.uint(4)
    req.endorsedAt = r.uint(4)
    req.locationKind = r.uint(1)
    req.locationId = r.uint(4)
    req.endorser = readCharacter(r)
    req.endorsee = readCharacter(r)
    return req
end

--- Decodes request bytes (the Q: message). Returns the request or nil; never errors.
function ns.DecodeRequest(bytes)
    if type(bytes) ~= "string" then return nil end
    local ok, req = pcall(function()
        local r = reader(bytes)
        local req = readRequest(r)
        if r.remaining() ~= 0 then error("trailing", 0) end
        return req
    end)
    return ok and req or nil
end

--- Decodes a finished record. Returns a table (request fields, ack fields, tags, recordMac, requestBytes) or nil,
-- also when the tags byte doesn't hold exactly one tag.
function ns.DecodeRecord(bytes)
    if type(bytes) ~= "string" then return nil end
    local ok, rec = pcall(function()
        local r = reader(bytes)
        local rec = readRequest(r)
        rec.requestBytes = sub(bytes, 1, r.pos - 1)
        rec.ackKeyVersion = r.uint(2)
        rec.ackLocationKind = r.uint(1)
        rec.ackLocationId = r.uint(4)
        rec.ackMac = r.raw(8)
        rec.tags = r.uint(1)
        if not ns.IsSingleTag(rec.tags) then error("tags", 0) end
        rec.recordMac = r.raw(12)
        if r.remaining() ~= 0 then error("trailing", 0) end
        return rec
    end)
    return ok and rec or nil
end

function ns.RecordToText(bytes)
    return ns.RECORD_TEXT_PREFIX .. ns.ToBase64Url(bytes)
end

--- Record bytes from an upload line, or nil.
function ns.RecordFromText(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if sub(text, 1, #ns.RECORD_TEXT_PREFIX) ~= ns.RECORD_TEXT_PREFIX then return nil end
    return ns.FromBase64Url(sub(text, #ns.RECORD_TEXT_PREFIX + 1))
end
