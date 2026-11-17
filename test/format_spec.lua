local loader = require("test.helpers.load_addon")

describe("FormatTooltipLine", function()
    local ns = loader.load({ "Format.lua" })

    it("matches the site's tooltip preview", function()
        assert.are.equal("LFG+ Endorsed by 27 \194\183 Calm", ns.FormatTooltipLine(27, 2))
        assert.are.equal("LFG+ Endorsed by 83 \194\183 Leader", ns.FormatTooltipLine(83, 8))
    end)

    it("leaves the tag out when the data has none", function()
        assert.are.equal("LFG+ Endorsed by 5", ns.FormatTooltipLine(5, 0))
        assert.are.equal("LFG+ Endorsed by 5", ns.FormatTooltipLine(5, nil))
    end)

    it("says so when there is nothing to show", function()
        assert.are.equal("LFG+ No endorsements yet", ns.FormatTooltipLine(nil))
    end)
end)

describe("FormatYouEndorsedLine", function()
    local ns = loader.load({ "Format.lua" })

    it("names the tag you gave, with the LFG+ prefix only when it stands alone", function()
        assert.are.equal("You endorsed them \194\183 Calm", ns.FormatYouEndorsedLine(2, false))
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
        assert.are.equal("Calm", ns.TagText(2))
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

    it("finds characters in the data add-on by their key", function()
        local count, tag = ns.LookupCharacter(id("Bright Mend"))
        assert.are.equal(27, count)
        assert.are.equal(2, tag)
        assert.is_nil(ns.LookupCharacter(id("Nobody")))
        assert.is_nil(ns.LookupCharacter(nil, false))
    end)

    it("matches WoW Forever full names, ignoring case and extra spacing, and non-ASCII names", function()
        assert.are.equal(42, (ns.LookupCharacter(id("Middle Foot"))))
        assert.are.equal(17, (ns.LookupCharacter(id("left foot"))))
        assert.are.equal(131, (ns.LookupCharacter(id("  Sir   Rocky "))))
        assert.are.equal(6, (ns.LookupCharacter(id("Sölving Problems"))))
        local count, tag = ns.LookupCharacter(id("Sir Pebbles"))
        assert.are.equal(6, count)
        assert.are.equal(0, tag)
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
        assert.is_false(LFGPlus_RegisterData({ format = 3, gameVersion = 40, region = 1, entries = {} }))
        assert.are.equal("unsupported", ns.dataStatus.state)
        assert.is_false(LFGPlus_RegisterData({ format = 0, gameVersion = 30, region = 1, entries = {} }))
        assert.is_false(LFGPlus_RegisterData({ format = 0, gameVersion = 40, region = 2, entries = {} }))
        assert.are.equal("mismatch", ns.dataStatus.state)
        assert.is_nil(ns.data)
        assert.truthy(LFGPlus_RegisterData({ format = 0, gameVersion = 40, region = 1, day = "2026-11-08", players = 0, entries = {} }))
        assert.are.equal("Data: 0 players, from 2026-11-08.", ns.DataStatusLine())
    end)
end)
