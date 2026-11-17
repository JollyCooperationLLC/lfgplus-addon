-- Setup code v1: "LFG1:" + 70 characters of base64url carrying the account id, key version,
-- account secret and a 2-byte SHA-256 checksum. Pure functions, proven against test/test-vectors/setup-code.json.
-- The code is a secret: never print it, nor anything decoded from it.

local _, ns = ...

local byte, char, sub = string.byte, string.char, string.sub
local floor = math.floor

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local VALUE = {}
for i = 1, #ALPHABET do VALUE[byte(ALPHABET, i)] = i - 1 end

local PREFIX = "LFG1:"
local BODY_CHARS = 70

--- Strict, canonical base64url (no padding) to bytes, or nil: unknown characters, a length of 1 mod 4 and non-zero
-- spare bits in the last character are all refused, so every byte string has exactly one accepted spelling.
function ns.FromBase64Url(text)
    if type(text) ~= "string" or #text % 4 == 1 then return nil end
    local out, acc, bits = {}, 0, 0
    for i = 1, #text do
        local v = VALUE[byte(text, i)]
        if not v then return nil end
        acc = acc * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            local divisor = 2 ^ bits
            out[#out + 1] = char(floor(acc / divisor))
            acc = acc % divisor
        end
    end
    if acc ~= 0 then return nil end -- spare bits must be zero
    return table.concat(out)
end

local function trim(text)
    return (text:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

--- Decodes a pasted setup code to { accountId = 32 hex chars, keyVersion = number, accountSecret = 32-byte string },
-- or nil for anything that isn't a valid v1 code. Never errors.
function ns.ParseSetupCode(text)
    if type(text) ~= "string" then return nil end
    text = trim(text)
    if #text ~= #PREFIX + BODY_CHARS or sub(text, 1, #PREFIX) ~= PREFIX then return nil end
    local bytes = ns.FromBase64Url(sub(text, #PREFIX + 1))
    if not bytes or #bytes ~= 52 then return nil end
    if sub(ns.Sha256(sub(bytes, 1, 50)), 1, 2) ~= sub(bytes, 51, 52) then return nil end
    local high, low = byte(bytes, 17, 18)
    local keyVersion = high * 256 + low
    if keyVersion == 0 then return nil end
    return {
        accountId = ns.ToHex(sub(bytes, 1, 16)),
        keyVersion = keyVersion,
        accountSecret = sub(bytes, 19, 50),
    }
end
