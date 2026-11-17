-- Proves Crypto.lua against the shared vectors (the same files the TypeScript core checks) and SHA-256 references at
-- every padding boundary. Runs in real Lua 5.1 with LuaBitOp standing in for WoW's `bit` library.
_G.bit = _G.bit or require("bit")
local loader = require("test.helpers.load_addon")

local ns = loader.load({ "Crypto.lua" })

--- The test pattern used for the boundary digests: byte i (0-based) is (i * 7 + 1) % 256.
local function pattern(n)
    local bytes = {}
    for i = 0, n - 1 do bytes[#bytes + 1] = string.char((i * 7 + 1) % 256) end
    return table.concat(bytes)
end

describe("Sha256", function()
    it("matches the FIPS 180-2 examples", function()
        assert.are.equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ns.ToHex(ns.Sha256("")))
        assert.are.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ns.ToHex(ns.Sha256("abc")))
        assert.are.equal("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            ns.ToHex(ns.Sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
    end)

    -- References from Python's hashlib over the same pattern: one and two blocks, either side of the 56-byte cutoff.
    local boundaries = {
        [55] = "16fa57a0a3423a715d594516339f36189d6b5f93754a9714fef202616a9fabfe",
        [56] = "c37b44e5f1b18554b36966f4f8e08bfbf3164c4b6c10374d12d89850892073c5",
        [63] = "bbba992d2c85af960fb2987a1fd05e0aa82a3db3c740dd8982a9e273b75e36a3",
        [64] = "66bd4633ed6f71c4ecfa4763bf7ba1c8ec7612de9aa6c0578a7b675207c71e0b",
        [119] = "a3ed307b730fa77c07531300c6e4a282330011d4d4caf6bb7b63ae05950f4b66",
        [1000] = "095ecb62e30793ab4b954cd6a0586d0cc91f7ea5b1332694d8da780e98676d78",
    }
    for length, digest in pairs(boundaries) do
        it("hashes a " .. length .. "-byte message", function()
            assert.are.equal(digest, ns.ToHex(ns.Sha256(pattern(length))))
        end)
    end
end)

describe("HmacSha256", function()
    local vectors = loader.read_vectors("hmac-sha256.json")
    for _, case in ipairs(vectors.cases) do
        it("reproduces " .. case.name, function()
            local data = case.dataUtf8 or ns.FromHex(case.dataHex)
            assert.are.equal(case.macHex, ns.ToHex(ns.HmacSha256(ns.FromHex(case.keyHex), data)))
        end)
    end

    it("refuses an empty key, like the TypeScript core", function()
        assert.has_error(function() ns.HmacSha256("", "data") end)
    end)
end)

describe("DeriveAddonKeys", function()
    local vectors = loader.read_vectors("key-derivation.json")
    local master = ns.FromHex(vectors.masterSecretHex)
    for _, case in ipairs(vectors.cases) do
        it("matches the server for account " .. case.accountId .. " key version " .. case.keyVersion, function()
            -- The server derives the account secret; checking it here proves the label format both sides use.
            local accountSecret = ns.HmacSha256(master, "lfgplus/account/v1/" .. case.keyVersion .. "/" .. case.accountId)
            assert.are.equal(case.accountSecretHex, ns.ToHex(accountSecret))

            local keys = ns.DeriveAddonKeys(ns.FromHex(case.accountSecretHex))
            assert.are.equal(case.realKeyHex, ns.ToHex(keys.real))
            assert.are.equal(case.dropKeyHex, ns.ToHex(keys.drop))
            assert.are.equal(case.ackKeyHex, ns.ToHex(keys.ack))
        end)
    end
end)

describe("FromHex / ToHex", function()
    it("round-trips every byte value", function()
        local all = {}
        for i = 0, 255 do all[#all + 1] = string.char(i) end
        local bytes = table.concat(all)
        assert.are.equal(bytes, ns.FromHex(ns.ToHex(bytes)))
        assert.are.equal(bytes, ns.FromHex(ns.ToHex(bytes):upper()))
    end)

    it("returns nil for malformed hex, so a bad setup code fails cleanly", function()
        assert.is_nil(ns.FromHex("abc"))   -- odd length
        assert.is_nil(ns.FromHex("zz"))    -- not hex
        assert.is_nil(ns.FromHex("0x00"))  -- prefix
        assert.is_nil(ns.FromHex(nil))
    end)
end)
