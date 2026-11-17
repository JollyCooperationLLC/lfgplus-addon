-- Proves SetupCode.lua against test/test-vectors/setup-code.json, the same file the TypeScript codec checks.
_G.bit = _G.bit or require("bit")
local loader = require("test.helpers.load_addon")

local ns = loader.load({ "Crypto.lua", "SetupCode.lua" })
local vectors = loader.read_vectors("setup-code.json")

describe("ParseSetupCode", function()
    for _, case in ipairs(vectors.valid) do
        it("decodes the code for account " .. case.accountId .. " key version " .. case.keyVersion, function()
            local code = ns.ParseSetupCode(case.input)
            assert.is_table(code)
            assert.are.equal(case.accountId, code.accountId)
            assert.are.equal(case.keyVersion, code.keyVersion)
            assert.are.equal(case.accountSecretHex, ns.ToHex(code.accountSecret))
        end)
    end

    for _, case in ipairs(vectors.invalid) do
        it("refuses a code with " .. case.reason, function()
            assert.is_nil(ns.ParseSetupCode(case.input))
        end)
    end

    it("refuses things that aren't strings", function()
        assert.is_nil(ns.ParseSetupCode(nil))
        assert.is_nil(ns.ParseSetupCode(42))
        assert.is_nil(ns.ParseSetupCode({}))
    end)
end)

describe("FromBase64Url", function()
    it("matches RFC 4648 test strings (unpadded, url alphabet)", function()
        local expected = { [""] = "", Zg = "f", Zm8 = "fo", Zm9v = "foo", Zm9vYg = "foob", Zm9vYmE = "fooba", Zm9vYmFy = "foobar" }
        for text, bytes in pairs(expected) do assert.are.equal(bytes, ns.FromBase64Url(text)) end
        assert.are.equal("\251\255", ns.FromBase64Url("-_8"))
    end)

    it("refuses impossible lengths, foreign characters and non-zero spare bits", function()
        assert.is_nil(ns.FromBase64Url("A"))
        assert.is_nil(ns.FromBase64Url("Zm9v+"))
        assert.is_nil(ns.FromBase64Url("Zm9v="))
        assert.is_nil(ns.FromBase64Url("Zh"))
    end)
end)
