-- Proves Data.lua's format-3 loading and lookup against test/test-vectors/export-v3.json,
-- which the site's export writes: each case is a whole data add-on, whose files are run here as the
-- game client runs them, and every lookup must answer the same four counts, or nothing.
_G.bit = _G.bit or require("bit") -- LuaBitOp stands in for WoW's `bit` library (Crypto.lua)
local loader = require("test.helpers.load_addon")
local vectors = loader.read_vectors("export-v3.json")
local null = require("dkjson").null

local function fromHex(hex)
    return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

--- A chunk's fields as its Data_<nnnn>.lua passes them, from a vector file's fields.
local function chunk(case, file, extra)
    local d = {
        format = 3, gameVersion = vectors.gameVersion, region = vectors.region, day = vectors.day,
        bits = case.bits, chunk = file.chunk, chunks = case.chunks, players = file.players,
        k = file.k, entries = file.entries, palettes = file.palettes, index = file.index,
        exceptions = file.exceptions, data = fromHex(file.dataHex),
    }
    for key, value in pairs(extra or {}) do d[key] = value end
    return d
end

local several, shared, wide = vectors.cases[1], vectors.cases[2], vectors.cases[3]

describe("format 3 (packed, chunked) data", function()
    local ns
    local function fresh()
        _G.GetCurrentRegion = function() return 1 end
        ns = loader.load({ "Core.lua", "Log.lua", "Identity.lua", "Crypto.lua", "Data.lua" })
        ns.gameVersion = 40
        return ns
    end
    before_each(fresh)

    --- Every lookup of a case, against whatever is loaded.
    local function assertLookups(case)
        for _, lookup in ipairs(case.lookups) do
            local counts = ns.LookupCharacter({ key = lookup.key }, false)
            if lookup.value == nil or lookup.value == null then
                assert.is_nil(counts, case.name .. ": " .. lookup.key)
            else
                assert.are.same(lookup.value, counts, case.name .. ": " .. lookup.key)
            end
        end
    end

    local function players(case)
        local total = 0
        for _, file in ipairs(case.files) do total = total + file.players end
        return total
    end

    it("computes the same fingerprints as the server, at 40, 48 and 52 bits", function()
        -- SHA-256("middle foot") starts c4 fb 09 1f 40 d4 c9; the numbers are Node's.
        assert.are.equal(846025269056, ns.Fingerprint("middle foot", 40))
        assert.are.equal(216582468878548, ns.Fingerprint("middle foot", 48))
        assert.are.equal(3465319502056780, ns.Fingerprint("middle foot", 52))
    end)

    it("runs every file of each data add-on as the client would, and answers every lookup exactly as the encoder", function()
        for _, case in ipairs(vectors.cases) do
            fresh()
            for i, file in ipairs(case.files) do
                assert.is_nil(ns.data, case.name) -- no data until the last file
                assert.is_false(ns.HasData())
                assert(loadstring(fromHex(file.fileHex), file.name))()
                if i < #case.files then
                    assert.are.equal(("Data: none (%d of %d data files loaded)."):format(i, #case.files), ns.DataStatusLine())
                end
            end
            assert.is_true(ns.HasData())
            assert.are.equal(("Data: %d players, from %s."):format(players(case), vectors.day), ns.DataStatusLine())
            assertLookups(case)
        end
    end)

    it("answers the same from the vectors' fields, with the files registered in any order", function()
        for _, case in ipairs(vectors.cases) do
            fresh()
            for i = #case.files, 1, -1 do assert.is_true(LFGPlus_RegisterData(chunk(case, case.files[i]))) end
            assertLookups(case)
        end
    end)

    it("holds shared fingerprints and borrowed names as exceptions of their chunk, and has empty chunks", function()
        local withValues, falses, empty = 0, 0, 0
        for _, file in ipairs(shared.files) do
            for _, value in pairs(file.exceptions) do
                if value then withValues = withValues + 1 else falses = falses + 1 end
            end
            if file.players == 0 then empty = empty + 1 end
        end
        assert.are.equal(2, withValues)
        assert.are.equal(1, falses)
        assert.is_true(empty > 0)
    end)

    it("remembers answers, found or not, so a tooltip hashes each name once", function()
        for _, file in ipairs(several.files) do LFGPlus_RegisterData(chunk(several, file)) end
        local hashes = 0
        local sha = ns.Sha256
        ns.Sha256 = function(m) hashes = hashes + 1 return sha(m) end
        local first = several.lookups[1]
        assert.is_table(ns.LookupCharacter({ key = first.key }, false))
        ns.LookupCharacter({ key = first.key }, false)
        ns.LookupCharacter({ key = "nobody here" }, false)
        ns.LookupCharacter({ key = "nobody here" }, false)
        assert.are.equal(2, hashes)
    end)

    it("reads a chunk's exceptions first: a value, or false for a known name that isn't in the file", function()
        local first = wide.lookups[1]
        local fp = ns.Fingerprint(first.key, wide.bits)
        local d = chunk(wide, wide.files[1], { exceptions = { ["collided name"] = { 0, 0, 12, 3 }, [first.key] = false } })
        assert.are.same({ 0, 0, 12, 3 }, ns.PackedLookup(d, "collided name", 0))
        assert.is_nil(ns.PackedLookup(d, first.key, fp))
        local bare = chunk(wide, wide.files[1])
        bare.exceptions = nil -- no exceptions table at all
        assert.is_table(ns.PackedLookup(bare, first.key, fp))
    end)

    it("answers nothing before the first block or from an empty chunk", function()
        local d = chunk(wide, wide.files[1], { index = { 2 ^ 52 - 1, 0 } })
        assert.is_nil(ns.PackedLookup(d, "nobody here", 5))
        assert.is_nil(ns.PackedLookup(chunk(wide, wide.files[1], { index = {}, entries = 0, palettes = { {}, {}, {}, {} }, data = "" }), "anyone", 5))
    end)

    it("ends a search on corrupt data instead of failing", function()
        local first = wide.lookups[1]
        local fp = ns.Fingerprint(first.key, wide.bits)
        -- Fun's one symbol has length 2: a stream of 1 bits never matches its code 00.
        local palettes = { { 5, 2 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }
        assert.is_nil(ns.PackedLookup(chunk(wide, wide.files[1], { palettes = palettes, data = string.rep("\255", 4096) }), first.key, fp))
        -- Truncated: past the end reads zeros, which still decode to something, and the search stops.
        local counts = ns.PackedLookup(chunk(wide, wide.files[1], { data = "" }), first.key, fp)
        assert.is_true(counts == nil or type(counts) == "table")
    end)

    it("refuses a file that lacks its fields, format 1, which was never released, and format 2, one count each", function()
        local file = wide.files[1]
        assert.is_false(LFGPlus_RegisterData({ format = 3, gameVersion = 40, region = 1, entries = {} }))
        for _, field in ipairs({ "data", "index", "palettes", "k", "entries", "players" }) do
            assert.is_false(LFGPlus_RegisterData(chunk(wide, file, { [field] = true })), field)
        end
        for missing = 1, 4 do -- a palette for every tag
            local palettes = { {}, {}, {}, {} }
            palettes[missing] = nil
            assert.is_false(LFGPlus_RegisterData(chunk(wide, file, { palettes = palettes })), "palette " .. missing)
        end
        assert.is_false(LFGPlus_RegisterData(chunk(wide, file, { format = 1 })))
        assert.are.equal("Data: none (format 1).", ns.DataStatusLine())
        assert.is_false(LFGPlus_RegisterData(chunk(wide, file, { format = 2 })))
        assert.are.equal("Data: none (format 2).", ns.DataStatusLine())
        assert.is_nil(ns.data)
    end)

    it("refuses a file whose fingerprint width, file count or file number can't be right", function()
        local file = several.files[1]
        local function refused(extra, reason)
            fresh()
            assert.is_false(LFGPlus_RegisterData(chunk(several, file, extra)), reason)
            assert.are.equal("unsupported", ns.dataStatus.state)
            assert.are.equal("Data: none (" .. reason .. ").", ns.DataStatusLine())
            assert.is_nil(ns.data)
        end
        refused({ bits = 39 }, "a fingerprint of 39 bits")
        refused({ bits = 53 }, "a fingerprint of 53 bits")
        refused({ bits = 48.5 }, "a fingerprint of 48.5 bits")
        refused({ bits = "48" }, "a fingerprint of 48 bits")
        refused({ chunks = 0 }, "0 data files")
        refused({ chunks = 3 }, "3 data files")
        refused({ chunks = 12 }, "12 data files")
        refused({ chunks = 8192 }, "8192 data files")
        refused({ chunks = 1.5 }, "1.5 data files")
        refused({ chunk = -1 }, "data file -1 of 2")
        refused({ chunk = 2 }, "data file 2 of 2")
        refused({ chunk = 0.5 }, "data file 0.5 of 2")
        -- The widest and the largest the format allows are fine.
        fresh()
        assert.is_true(LFGPlus_RegisterData(chunk(several, file, { bits = 52, chunks = 4096, chunk = 4095 })))
        assert.are.equal("Data: none (1 of 4096 data files loaded).", ns.DataStatusLine())
    end)

    it("drops every file when two downloads are mixed, and takes no more this session", function()
        local a, b = several.files[1], several.files[2]
        local function mixed(second, reason)
            fresh()
            assert.is_true(LFGPlus_RegisterData(chunk(several, a)))
            assert.is_false(LFGPlus_RegisterData(second))
            assert.are.equal("mixed", ns.dataStatus.state)
            assert.are.equal("Data: none (" .. reason .. ").", ns.DataStatusLine())
            -- The file that would have completed the set is refused too: yesterday's and today's never mix.
            assert.is_false(LFGPlus_RegisterData(chunk(several, b)))
            assert.is_nil(ns.data)
            assert.is_nil(ns.LookupCharacter({ key = several.lookups[1].key }, false))
        end
        mixed(chunk(several, b, { day = "2026-11-07" }), "files from different days")
        mixed(chunk(several, b, { bits = 40 }), "files from different days")
        mixed(chunk(several, b, { chunks = 4 }), "files from different days")
        mixed(chunk(several, a), "data file 0 arrived twice")
    end)

    it("leaves a file for another game version or region out, so that data add-on never completes", function()
        assert.is_true(LFGPlus_RegisterData(chunk(several, several.files[1])))
        assert.is_false(LFGPlus_RegisterData(chunk(several, several.files[2], { region = 2 })))
        assert.are.equal("mismatch", ns.dataStatus.state)
        assert.is_nil(ns.data)
    end)

    it("says so when the data add-on finished loading with files missing", function()
        _G.C_AddOns = { LoadAddOn = function()
            LFGPlus_RegisterData(chunk(several, several.files[1]))
            return true
        end }
        ns.LoadDataAddon()
        _G.C_AddOns = nil
        assert.are.equal("incomplete", ns.dataStatus.state)
        assert.are.equal("Data: none (1 of 2 data files loaded).", ns.DataStatusLine())
        assert.is_false(ns.HasData())
        assert.is_nil(ns.LookupCharacter({ key = several.lookups[1].key }, false))
    end)
end)
