local loader = require("test.helpers.load_addon")

describe("FormatTooltipRows", function()
    local ns = loader.load({ "Format.lua" })
    local media = "Interface\\AddOns\\LFGPlus\\Media\\"

    it("matches the site's tooltip preview: a row per tag, in tag order, each with its icon and count", function()
        assert.are.equal("LFG+ Endorsements:", ns.TOOLTIP_HEADER)
        assert.are.same({
            { "|T" .. media .. "Tag-Fun:14:14|t Fun", "34" },
            { "|T" .. media .. "Tag-Skilled:14:14|t Skilled", "100" },
            { "|T" .. media .. "Tag-Helpful:14:14|t Helpful", "23" },
            { "|T" .. media .. "Tag-Leader:14:14|t Leader", "55" },
        }, ns.FormatTooltipRows({ 34, 100, 23, 55 }))
    end)

    it("leaves out a tag nobody picked, and a count the data lacks", function()
        assert.are.same({ { "|T" .. media .. "Tag-Skilled:14:14|t Skilled", "6" } }, ns.FormatTooltipRows({ 0, 6 }))
        local rows = ns.FormatTooltipRows({ 3, 0, 0, 9 })
        assert.are.same({ "3", "9" }, { rows[1][2], rows[2][2] })
    end)

    it("says so when there is nothing to show", function()
        assert.are.equal("LFG+ No endorsements yet", ns.TOOLTIP_NONE)
    end)
end)

describe("FormatYouEndorsedLine", function()
    local ns = loader.load({ "Format.lua" })

    it("names the tag you gave, with the LFG+ prefix only when it stands alone", function()
        assert.are.equal("You endorsed them \194\183 Skilled", ns.FormatYouEndorsedLine(2, false))
        assert.are.equal("LFG+ You endorsed them \194\183 Leader", ns.FormatYouEndorsedLine(8, true))
        assert.are.equal("You endorsed them", ns.FormatYouEndorsedLine(16, false))
    end)
end)

describe("Plural", function()
    local ns = loader.load({ "Format.lua" })

    it("drops the s for exactly one", function()
        assert.are.equal("0 endorsements", ns.Plural(0, "endorsement"))
        assert.are.equal("1 endorsement", ns.Plural(1, "endorsement"))
        assert.are.equal("20 real endorsements", ns.Plural(20, "real endorsement"))
    end)
end)

describe("TagText", function()
    local ns = loader.load({ "Format.lua" })

    it("names each tag bit, and several in display order", function()
        assert.are.equal("Fun", ns.TagText(1))
        assert.are.equal("Skilled", ns.TagText(2))
        assert.are.equal("Helpful", ns.TagText(4))
        assert.are.equal("Leader", ns.TagText(8))
        assert.are.equal("Fun \194\183 Helpful \194\183 Leader", ns.TagText(13))
    end)

    it("gives nil when no known tag is set", function()
        assert.is_nil(ns.TagText(0))
        assert.is_nil(ns.TagText(16))
        assert.is_nil(ns.TagText(nil))
        assert.is_nil(ns.TagText("x"))
    end)
end)

describe("ThanksText", function()
    local ns = loader.load({ "Format.lua" })

    it("thanks each tag in its own words, from LFG.plus, within one chat message", function()
        local seen = {}
        for _, tag in ipairs({ 1, 2, 4, 8 }) do
            local text = ns.ThanksText(tag)
            assert.are.equal("[LFG.plus] Thanks for ", text:sub(1, 22))
            assert.truthy(text:find("I endorsed you as " .. ns.TAG_LABELS[tag] .. ".", 1, true))
            assert.is_true(#text <= 255)
            assert.is_nil(seen[text])
            seen[text] = true
        end
    end)

    it("falls back to a plain thank-you for a tag it doesn't know", function()
        assert.are.equal("[LFG.plus] Thanks for the group! I endorsed you.", ns.ThanksText(16))
    end)
end)

describe("Core", function()
    local ns = loader.load({ "Core.lua" })

    it("fills missing saved variables without overwriting the player's choices", function()
        local db = ns.ApplyDefaults({ toastSound = false }, { toastSound = true, nested = { used = 0 } })
        assert.is_false(db.toastSound)
        assert.are.same({ used = 0 }, db.nested)
    end)

    it("tells game versions apart by interface number", function()
        assert.are.equal(ns.GameVersions.RETAIL, ns.GameVersionForInterface(120105))
        assert.are.equal(ns.GameVersions.FOREVER, ns.GameVersionForInterface(16001))
        assert.are.equal(ns.GameVersions.CLASSIC_ERA, ns.GameVersionForInterface(11509))
        assert.are.equal(ns.GameVersions.CLASSIC, ns.GameVersionForInterface(50504))
        assert.are.equal(ns.GameVersions.ANNIVERSARY, ns.GameVersionForInterface(20506))
    end)

    it("starts up on ADDON_LOADED for LFG+ only, even without the log, settings or minimap files", function()
        local world = require("test.helpers.wow_stubs").install({})
        _G.LFGPlusDB = nil
        local core = loader.load({ "Core.lua" })
        world.fire("ADDON_LOADED", "SomeOtherAddOn")
        assert.is_nil(core.db)
        world.fireAddonLoaded()
        assert.are.equal(LFGPlusDB, core.db)
        assert.are.equal(core.GameVersions.RETAIL, core.gameVersion)
        assert.truthy(world.chat[1]:find("v0.1.0-test loaded", 1, true))
        _G.LFGPlusDB = nil
    end)
end)

describe("LookupCharacter", function()
    local ns
    before_each(function()
        _G.GetCurrentRegion = function() return 1 end
        ns = loader.load({ "Core.lua", "Log.lua", "Identity.lua", "Data.lua" })
        ns.gameVersion = 40
        -- The generated development data add-on, as the client would run it.
        assert(require("test.helpers.coverage").load("LFGPlus_Data_Forever_US/Data.lua"))()
    end)
    local function id(name) return { name = name, realm = "", key = ns.CharacterKey(name, "") } end

    it("finds characters in the data add-on by their key: four counts, Fun, Skilled, Helpful and Leader", function()
        assert.are.same({ 5, 12, 6, 4 }, ns.LookupCharacter(id("Bright Mend")))
        assert.is_nil(ns.LookupCharacter(id("Nobody")))
        assert.is_nil(ns.LookupCharacter(nil, false))
    end)

    it("matches WoW Forever full names, ignoring case and extra spacing, and non-ASCII names", function()
        assert.are.same({ 30, 6, 4, 2 }, ns.LookupCharacter(id("Middle Foot")))
        assert.are.same({ 3, 10, 2, 2 }, ns.LookupCharacter(id("left foot")))
        assert.are.same({ 20, 31, 30, 50 }, ns.LookupCharacter(id("  Sir   Rocky ")))
        assert.are.same({ 0, 6, 0, 0 }, ns.LookupCharacter(id("Sölving Problems")))
        assert.are.same({ 2, 2, 1, 1 }, ns.LookupCharacter(id("Sir Pebbles")))
    end)
end)

describe("LFGPlus_RegisterData", function()
    local ns
    before_each(function()
        _G.GetCurrentRegion = function() return 1 end
        ns = loader.load({ "Core.lua", "Log.lua", "Identity.lua", "Data.lua" })
        ns.gameVersion = 40
    end)

    it("names the data add-on for each game version and region", function()
        assert.are.equal("LFGPlus_Data_Forever_US", ns.DataAddonName(40, 1))
        assert.are.equal("LFGPlus_Data_ClassicEra_EU", ns.DataAddonName(30, 2))
        assert.are.equal("LFGPlus_Data_Anniversary_US", ns.DataAddonName(50, 1))
        assert.is_nil(ns.DataAddonName(40, 9))
    end)

    it("refuses an unknown format, or data for another game version or region", function()
        assert.is_false(LFGPlus_RegisterData({ format = 4, gameVersion = 40, region = 1, entries = {} }))
        assert.are.equal("unsupported", ns.dataStatus.state)
        assert.is_false(LFGPlus_RegisterData({ format = 0, gameVersion = 30, region = 1, entries = {} }))
        assert.is_false(LFGPlus_RegisterData({ format = 0, gameVersion = 40, region = 2, entries = {} }))
        assert.are.equal("mismatch", ns.dataStatus.state)
        assert.is_nil(ns.data)
        assert.truthy(LFGPlus_RegisterData({ format = 0, gameVersion = 40, region = 1, day = "2026-11-08", players = 0, entries = {} }))
        assert.are.equal("Data: 0 players, from 2026-11-08.", ns.DataStatusLine())
    end)
end)
