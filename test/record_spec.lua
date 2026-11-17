-- Proves Record.lua against test/test-vectors/record-v1.json, byte for byte with the site's codec.
_G.bit = _G.bit or require("bit")
local loader = require("test.helpers.load_addon")

local ns = loader.load({ "Crypto.lua", "SetupCode.lua", "Record.lua" })
local vectors = loader.read_vectors("record-v1.json")

-- dkjson decodes JSON null as a sentinel, not nil; turn it back into nil for GUIDs.
local function character(c)
    return { name = c.name, realm = c.realm, guid = type(c.guid) == "string" and c.guid or nil }
end

local function request(c)
    local r = {}
    for k, v in pairs(c.request) do r[k] = v end
    r.endorser, r.endorsee = character(c.request.endorser), character(c.request.endorsee)
    return r
end

describe("Record v1", function()
    for _, c in ipairs(vectors.cases) do
        describe(c.name, function()
            local req = request(c)
            local requestBytes = ns.EncodeRequest(req)

            it("encodes the request bytes", function()
                assert.are.equal(c.requestHex, ns.ToHex(requestBytes))
            end)

            it("computes the ack MAC", function()
                if type(c.ackKeyHex) ~= "string" then return end
                assert.are.equal(c.ack.ackMacHex, ns.ToHex(ns.AckMac(ns.FromHex(c.ackKeyHex), requestBytes, c.ack.ackLocationKind, c.ack.ackLocationId)))
            end)

            it("signs the real and quiet records exactly like the server", function()
                local ack = { ackKeyVersion = c.ack.ackKeyVersion, ackLocationKind = c.ack.ackLocationKind, ackLocationId = c.ack.ackLocationId, ackMac = ns.FromHex(c.ack.ackMacHex) }
                assert.are.equal(c.realText, ns.RecordToText(ns.EncodeRecord(requestBytes, ack, c.tags, ns.FromHex(c.realKeyHex))))
                assert.are.equal(c.dropText, ns.RecordToText(ns.EncodeRecord(requestBytes, ack, c.tags, ns.FromHex(c.dropKeyHex))))
            end)

            it("decodes its own upload line back to every field", function()
                local rec = ns.DecodeRecord(ns.RecordFromText(c.realText))
                assert.is_table(rec)
                assert.are.equal(c.request.counter, rec.counter)
                assert.are.equal(c.request.endorserAccount, rec.endorserAccount)
                assert.are.equal(c.request.endorsee.name, rec.endorsee.name)
                assert.are.equal(c.request.endorser.realm, rec.endorser.realm)
                assert.are.equal(character(c.request.endorsee).guid, rec.endorsee.guid)
                assert.are.equal(character(c.request.endorser).guid, rec.endorser.guid)
                assert.are.equal(c.tags, rec.tags)
                assert.are.equal(c.ack.ackKeyVersion, rec.ackKeyVersion)
                assert.are.equal(c.requestHex, ns.ToHex(rec.requestBytes))
                assert.are.same(ns.DecodeRequest(requestBytes).endorsee, rec.endorsee)
            end)
        end)
    end

    it("signs exactly one tag: never none, two at once or an unknown bit", function()
        local c = vectors.cases[1]
        local requestBytes = ns.FromHex(c.requestHex)
        for _, tags in ipairs({ 0, 3, 16, 256 }) do
            local ok, err = pcall(ns.EncodeRecord, requestBytes, ns.UNPROVEN_ACK, tags, ns.FromHex(c.realKeyHex))
            assert.is_false(ok)
            assert.truthy(tostring(err):find("exactly one tag", 1, true))
        end
        for _, tags in ipairs({ 1, 2, 4, 8 }) do
            assert.is_true(ns.IsSingleTag(tags))
            assert.are.equal(tags, ns.DecodeRecord(ns.EncodeRecord(requestBytes, ns.UNPROVEN_ACK, tags, ns.FromHex(c.realKeyHex))).tags)
        end
        assert.is_false(ns.IsSingleTag(nil))
    end)

    for _, v in ipairs(vectors.invalid) do
        it("refuses a record with " .. v.reason, function()
            assert.is_nil(ns.DecodeRecord(ns.FromHex(v.hex)))
        end)
    end

    it("encodes names up to 64 bytes and refuses longer ones", function()
        local req = request(vectors.cases[1])
        req.endorsee = { name = string.rep("x", 64), realm = string.rep("y", 64) }
        assert.are.same(req.endorsee, ns.DecodeRequest(assert(ns.EncodeRequest(req))).endorsee)
        req.endorsee = { name = string.rep("x", 65), realm = "" }
        local bytes, err = ns.EncodeRequest(req)
        assert.is_nil(bytes)
        assert.truthy(err:find("64 bytes", 1, true))
    end)

    --- Case 1's request with some fields replaced.
    local function with(changes)
        local r = request(vectors.cases[1])
        for k, v in pairs(changes) do r[k] = v end
        return r
    end

    it("refuses to encode a field out of range, an empty name, a bad account, key version or GUID", function()
        for _, changes in ipairs({
            { counter = -1 }, { counter = 1.5 }, { gameVersion = 256 },
            { endorsee = { name = "", realm = "" } },
            { endorsee = { name = "Middle Foot", realm = "", guid = "Player-\1" } },
            { endorserAccount = "ABCDEF0123456789ABCDEF0123456789" }, -- upper case: one spelling only
            { endorserAccount = "abcd" },
            { keyVersion = 0 },
        }) do
            local bytes, err = ns.EncodeRequest(with(changes))
            assert.is_nil(bytes)
            assert.is_string(err)
        end
    end)

    it("round-trips multi-byte UTF-8 names and server ids too long or too large for the compact GUID", function()
        for _, endorsee in ipairs({
            { name = "Zo\195\171 Smith", realm = "" },                                 -- 2-byte character
            { name = "\226\130\172uro Coin", realm = "" },                             -- 3-byte character
            { name = "\240\159\152\128 Smile", realm = "" },                           -- 4-byte character
            { name = "Middle Foot", realm = "", guid = "Player-12345678901-0A1B2C3D" }, -- 11-digit server
            { name = "Middle Foot", realm = "", guid = "Player-9999999999-0A1B2C3D" },  -- past 32 bits
        }) do
            local bytes = assert(ns.EncodeRequest(with({ endorsee = endorsee })))
            assert.are.same(endorsee, ns.DecodeRequest(bytes).endorsee)
        end
    end)

    it("refuses names that aren't strict UTF-8", function()
        for _, name in ipairs({
            "Bad\226\130",     -- cut short
            "Bad\226\40\172",  -- not a continuation byte
            "Bad\224\128\128", -- overlong
            "Bad\237\160\128", -- a surrogate
        }) do
            local bytes = assert(ns.EncodeRequest(with({ endorsee = { name = name, realm = "" } })))
            assert.is_nil(ns.DecodeRequest(bytes))
        end
    end)

    it("refuses a text GUID that has a compact form, trailing bytes, and anything that isn't a byte string or upload line", function()
        local bytes = assert(ns.EncodeRequest(with({ endorsee = { name = "Middle Foot", realm = "" } })))
        assert.are.equal("\2", bytes:sub(-1)) -- the endorsee comes last; kind 2 is "no GUID"
        local compact = "Player-4395-0A1B2C3D"
        assert.is_nil(ns.DecodeRequest(bytes:sub(1, -2) .. "\0" .. string.char(#compact) .. compact))
        assert.is_table(ns.DecodeRequest(bytes))
        assert.is_nil(ns.DecodeRequest(bytes .. "\0"))
        assert.is_nil(ns.DecodeRequest(nil))
        assert.is_nil(ns.DecodeRecord(42))
        assert.is_nil(ns.RecordFromText(nil))
        assert.is_nil(ns.RecordFromText("LFGX1:AAAA"))
    end)

    it("round-trips base64url for every length", function()
        for n = 0, 70 do
            local s = {}
            for i = 1, n do s[i] = string.char((i * 37) % 256) end
            local bytes = table.concat(s)
            assert.are.equal(bytes, ns.FromBase64Url(ns.ToBase64Url(bytes)))
        end
    end)
end)
