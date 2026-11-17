-- Proves Identity.lua's CharacterKey and Data.lua's Fingerprint against test/test-vectors/character-keys.json,
-- which the site writes: from a character's name as the game shows it and its realm as the game spells it inside
-- keys, the addon must build the same key and the same 48-bit fingerprint as the site, or tooltips miss them.
_G.bit = _G.bit or require("bit") -- LuaBitOp stands in for WoW's `bit` library (Crypto.lua)
local loader = require("test.helpers.load_addon")
local vectors = loader.read_vectors("character-keys.json")

describe("character keys and fingerprints", function()
    local ns = loader.load({ "Core.lua", "Log.lua", "Identity.lua", "Crypto.lua", "Data.lua" })

    it("builds every vector's key and 48-bit fingerprint, realms included", function()
        assert.is_true(#vectors.cases >= 8)
        for _, case in ipairs(vectors.cases) do
            local key = ns.CharacterKey(case.name, case.realm)
            assert.are.equal(case.key, key, case.note)
            assert.are.equal(case.fingerprint, ns.Fingerprint(key, 48), case.note)
        end
    end)

    it("keeps one name on two realms apart", function()
        local keys = {}
        for _, case in ipairs(vectors.cases) do
            if case.name == "Bob" then keys[#keys + 1] = ns.CharacterKey(case.name, case.realm) end
        end
        assert.are.equal(2, #keys)
        assert.are_not.equal(keys[1], keys[2])
    end)
end)
