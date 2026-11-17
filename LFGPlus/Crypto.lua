-- SHA-256, HMAC-SHA256 and the addon's key derivation, in plain Lua 5.1 on top of the game's `bit` library.
-- Pure functions over byte strings, so the busted suite proves them against the same vectors as the TypeScript core:
-- test/test-vectors/hmac-sha256.json (RFC 4231) and test/test-vectors/key-derivation.json.
--
-- Key derivation: the setup code carries the account secret,
-- and the addon derives realKey, dropKey and ackKey from it with HMAC. The labels are part of the format.

local _, ns = ...

local bit = bit -- WoW's global; the specs provide the same library (LuaBitOp)
local band, bor, bxor, bnot, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rshift, bit.lshift
local byte, char, format, rep = string.byte, string.char, string.format, string.rep
local floor = math.floor

local TWO32 = 4294967296

-- Bit ops may return signed results (LuaBitOp does); `% 2^32` maps every result back to 0 .. 2^32-1, so sums stay exact
-- in Lua 5.1's doubles.
local function u32(x) return x % TWO32 end
local function rotr(x, n) return u32(bor(rshift(x, n), lshift(x, 32 - n))) end
-- Two-argument calls only: not every `bit` library takes more.
local function bxor3(a, b, c) return bxor(bxor(a, b), c) end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function be32(x)
    return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
end

--- SHA-256 of a byte string, as a 32-byte string.
function ns.Sha256(message)
    local length = #message
    -- Pad: 0x80, zeros to 56 mod 64, then the bit length as 64-bit big-endian (messages here are far below 2^32 bytes).
    local bitLength = length * 8
    message = message .. "\128" .. rep("\0", (55 - length) % 64)
        .. be32(floor(bitLength / TWO32)) .. be32(bitLength % TWO32)

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local w = {}
    for chunk = 1, #message, 64 do
        for i = 0, 15 do
            local b1, b2, b3, b4 = byte(message, chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor3(rotr(x, 7), rotr(x, 18), rshift(x, 3))
            local s1 = bxor3(rotr(y, 17), rotr(y, 19), rshift(y, 10))
            w[i] = u32(w[i - 16] + u32(s0) + w[i - 7] + u32(s1))
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = u32(bxor3(rotr(e, 6), rotr(e, 11), rotr(e, 25)))
            local ch = u32(bxor(band(e, f), band(bnot(e), g)))
            local t1 = u32(h + S1 + ch + K[i + 1] + w[i])
            local S0 = u32(bxor3(rotr(a, 2), rotr(a, 13), rotr(a, 22)))
            local maj = u32(bxor3(band(a, b), band(a, c), band(b, c)))
            local t2 = u32(S0 + maj)
            h, g, f, e, d, c, b, a = g, f, e, u32(d + t1), c, b, a, u32(t1 + t2)
        end
        h0, h1, h2, h3 = u32(h0 + a), u32(h1 + b), u32(h2 + c), u32(h3 + d)
        h4, h5, h6, h7 = u32(h4 + e), u32(h5 + f), u32(h6 + g), u32(h7 + h)
    end
    return be32(h0) .. be32(h1) .. be32(h2) .. be32(h3) .. be32(h4) .. be32(h5) .. be32(h6) .. be32(h7)
end

local function xorWith(key, pad)
    local out = {}
    for i = 1, 64 do out[i] = char(bxor(byte(key, i), pad)) end
    return table.concat(out)
end

--- HMAC-SHA256 (RFC 2104) of a byte string under a byte-string key, as a 32-byte string.
function ns.HmacSha256(key, message)
    assert(#key > 0, "HMAC key must not be empty") -- same rule as the TypeScript core
    if #key > 64 then key = ns.Sha256(key) end
    key = key .. rep("\0", 64 - #key)
    return ns.Sha256(xorWith(key, 0x5c) .. ns.Sha256(xorWith(key, 0x36) .. message))
end

--- Lowercase hex of a byte string.
function ns.ToHex(bytes)
    return (bytes:gsub(".", function(c) return format("%02x", byte(c)) end))
end

--- Bytes from hex. Returns nil for odd-length or non-hex input, so a pasted setup code fails cleanly.
function ns.FromHex(hex)
    if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^0-9a-fA-F]") then return nil end
    return (hex:gsub("..", function(pair) return char(tonumber(pair, 16)) end))
end

ns.KEY_LABELS = {
    real = "lfgplus/key/real",
    drop = "lfgplus/key/drop",
    ack = "lfgplus/key/ack",
}

--- The three addon keys from the account secret in the setup code: { real =, drop =, ack = }, each 32 bytes.
function ns.DeriveAddonKeys(accountSecret)
    return {
        real = ns.HmacSha256(accountSecret, ns.KEY_LABELS.real),
        drop = ns.HmacSha256(accountSecret, ns.KEY_LABELS.drop),
        ack = ns.HmacSha256(accountSecret, ns.KEY_LABELS.ack),
    }
end
