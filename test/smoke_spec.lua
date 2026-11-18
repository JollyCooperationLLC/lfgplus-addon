-- Loads the whole addon against a fake WoW API (test/helpers/wow_stubs.lua) and drives it the way a player would.
-- Catches load-order mistakes, typos in globals and errors in the tooltip hook before anyone installs it.
local stubs = require("test.helpers.wow_stubs")
local loader = require("test.helpers.load_addon")

describe("the addon in a fake client", function()
    -- WoW Forever unless a spec says otherwise: the development data add-on (LFGPlus_Data_Forever_US) exists for
    -- it. Logging in is what loads the data.
    local function boot(options)
        options.interface = options.interface or 16001
        local world = stubs.install(options)
        local ns = world.loadAddon()
        world.fireAddonLoaded()
        world.fire("PLAYER_LOGIN")
        return world, ns
    end

    after_each(function() _G.LFGPlusDB = nil end)

    -- The LFG+ block of a player in the development data add-on, as world.texts reads it: a blank line first.
    local BRIGHT_MEND = { " ", "LFG+ Endorsements:", "Fun 5", "Skilled 12", "Helpful 6", "Leader 4" }
    local MIDDLE_FOOT = { " ", "LFG+ Endorsements:", "Fun 30", "Skilled 6", "Helpful 4", "Leader 2" }
    local SIR_ROCKY = { " ", "LFG+ Endorsements:", "Fun 20", "Skilled 31", "Helpful 30", "Leader 50" }
    local SIR_PEBBLES = { " ", "LFG+ Endorsements:", "Fun 2", "Skilled 2", "Helpful 1", "Leader 1" }
    local MOSS_BEARD = { " ", "LFG+ Endorsements:", "Fun 10", "Skilled 20", "Helpful 13", "Leader 40" }
    --- A block with lines before or after it.
    local function with(before, block, after)
        local t = { before }
        for _, line in ipairs(block) do t[#t + 1] = line end
        t[#t + 1] = after
        return t
    end

    it("loads every file in TOC order and greets the player once", function()
        local world, ns = boot({ interface = 120105, units = { player = { name = "Kaelwyn", realm = "Whitemane" } } })
        assert.are.equal(ns.GameVersions.RETAIL, ns.gameVersion)
        assert.is_table(LFGPlusDB)
        assert.are.equal(1, #world.chat)
        assert.truthy(world.chat[1]:find("v0.1.0-test loaded", 1, true))
    end)

    it("detects WoW Forever from its interface number", function()
        local _, ns = boot({ interface = 16001 })
        assert.are.equal(ns.GameVersions.FOREVER, ns.gameVersion)
    end)

    it("loads the data add-on for its game version and region at login", function()
        local world, ns = boot({ units = { player = { name = "Kaelwyn", realm = "Stone" } } })
        assert.are.same({ "LFGPlus_Data_Forever_US" }, world.loadedAddOns)
        assert.are.equal("loaded", ns.dataStatus.state)
        assert.are.equal("2026-11-07", ns.data.day)
        SlashCmdList.LFGPLUS("help")
        local found = false
        for _, line in ipairs(world.chat) do if line:find("Data: 8 players, from 2026-11-07.", 1, true) then found = true end end
        assert.truthy(found)
    end)

    it("adds no line at all when the data add-on is missing, and says where to get it", function()
        local world, ns = boot({ noDataAddOn = true, units = { player = { name = "Kaelwyn", realm = "Stone" }, target = { name = "Middle", realm = "Foot" } } })
        assert.are.equal(0, #world.hover("target"))
        assert.truthy(ns.DataStatusLine():find("LFGPlus_Data_Forever_US from lfg.plus/addon", 1, true))
        assert.are.equal(0, #world.hover("player"))
    end)

    it("adds no line on a game version with no data add-on yet", function()
        local world, ns = boot({ interface = 120105, units = { target = { name = "Thrallina", realm = "Whitemane" } } })
        assert.are.equal("missing", ns.dataStatus.state)
        assert.are.equal(0, #world.hover("target"))
    end)

    it("adds a green header and a row per tag for a known player, and a grey line for everyone else", function()
        local world = boot({ units = {
            player = { name = "Kaelwyn", realm = "Stone" },
            mouseover = { name = "Bright", realm = "Mend" },
            target = { name = "Stranger", realm = "Danger" },
        } })
        local known = world.hover("mouseover")
        assert.are.same(BRIGHT_MEND, world.texts(known))
        assert.are.equal(1.0, known[2].g)
        assert.are.same({ 1, 1, 1 }, { known[3].r, known[3].g, known[3].b }) -- the tag's name in white
        assert.are.same({ 0.118, 1.0, 0.0 }, { known[3].rr, known[3].rg, known[3].rb }) -- its count in green
        local unknown = world.hover("target")
        assert.are.same({ " ", "LFG+ No endorsements yet" }, world.texts(unknown))
        assert.are.equal(0.616, unknown[2].g)
    end)

    it("adds nothing, and never errors, when the client hides unit names (Midnight secret values)", function()
        local world = boot({ secretNames = true, units = { target = { name = "Hidden", realm = "Atiesh" } } })
        assert.has_no.errors(function() world.hover("target") end)
        assert.are.equal(0, #world.tooltip.lines)
    end)

    it("shows Forever first + last names, where UnitName's second value is the surname", function()
        -- As the real Forever client reports it.
        local world = boot({ interface = 16001, units = {
            player = { name = "Middle", realm = "Foot" },
            mouseover = { name = "Sir", realm = "Rocky" },
            target = { name = "Sir", realm = "Pebbles" },
        } })
        assert.are.same(MIDDLE_FOOT, world.texts(world.hover("player")))
        assert.are.same(SIR_ROCKY, world.texts(world.hover("mouseover")))
        assert.are.same(SIR_PEBBLES, world.texts(world.hover("target")))
    end)

    it("adds what you endorsed someone as under their line, and alone when there's no data add-on", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" }, mouseover = { name = "Bright", realm = "Mend" },
            target = { name = "Stranger", realm = "Danger" } }
        local world, ns = boot({ units = units })
        ns.db.endorsed[ns.UnitIdentity("mouseover").key] = { at = 1, tags = 4 }
        ns.db.endorsed[ns.UnitIdentity("target").key] = { at = 1, tags = 1 }
        local known = world.hover("mouseover")
        assert.are.same(with(nil, BRIGHT_MEND, "You endorsed them \194\183 Helpful"), world.texts(known))
        assert.are.equal(1.0, known[7].g)
        local unknown = world.hover("target")
        assert.are.same({ " ", "LFG+ No endorsements yet", "You endorsed them \194\183 Fun" }, world.texts(unknown))
        local bare, bareNs = boot({ noDataAddOn = true, units = units })
        bareNs.db.endorsed[bareNs.UnitIdentity("target").key] = { at = 1, tags = 1 }
        local alone = bare.hover("target")
        assert.are.same({ " ", "LFG+ You endorsed them \194\183 Fun" }, world.texts(alone))
    end)

    it("ignores tooltips for things that aren't players", function()
        local world = boot({ units = {} })
        assert.are.equal(0, #world.hover("npc"))
    end)

    it("answers its slash commands", function()
        local world = boot({ units = { player = { name = "Kaelwyn", realm = "Whitemane" }, target = { name = "Mossbeard", realm = "Atiesh" } } })
        SlashCmdList.LFGPLUS("help")
        assert.truthy(world.chat[#world.chat]:find("/endorse", 1, true))
        SlashCmdList.LFGPLUSENDORSE()
        assert.truthy(world.chat[#world.chat]:find("Link your LFG+ account first", 1, true))
        SlashCmdList.LFGPLUS("upload")
        assert.truthy(world.chat[#world.chat]:find("no endorsements to upload", 1, true))
    end)

    it("loads the data add-on through an older client's global LoadAddOn, and says so when there's no way to load it", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" } }
        local world, ns = boot({ loadAddOnApi = "global", units = units })
        assert.are.same({ "LFGPlus_Data_Forever_US" }, world.loadedAddOns)
        assert.are.equal("loaded", ns.dataStatus.state)
        local _, none = boot({ loadAddOnApi = "none", units = units })
        assert.are.equal("missing", none.dataStatus.state)
        assert.are.equal("NO_API", none.dataStatus.reason)
    end)

    it("loads the data add-on only once, and notices one that registers no data", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" } }
        local world, ns = boot({ units = units })
        ns.LoadDataAddon()
        assert.are.equal(1, #world.loadedAddOns)
        local _, empty = boot({ emptyDataAddOn = true, units = units })
        assert.are.equal("empty", empty.dataStatus.state)
        assert.are.equal("Data: none (empty).", empty.DataStatusLine())
    end)

    it("loads no data in a region LFG+ doesn't serve, and refuses data with no entries", function()
        local world, ns = boot({ clientRegion = 5, units = { player = { name = "Kaelwyn", realm = "Stone" } } })
        assert.are.equal(0, #world.loadedAddOns)
        assert.are.equal("Data: none (no data for this game version or region).", ns.DataStatusLine())
        assert.is_false(LFGPlus_RegisterData({ format = 0 }))
        assert.is_false(LFGPlus_RegisterData("nonsense"))
        assert.is_nil(ns.data)
    end)

    it("hooks GameTooltip on clients without TooltipDataProcessor, and adds nothing to other tooltips", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" }, mouseover = { name = "Bright", realm = "Mend" } }
        local world = boot({ tooltipApi = "hookscript", units = units })
        assert.are.same(BRIGHT_MEND, world.texts(world.hover("mouseover")))
        local other = { lines = {} } -- a second tooltip (a comparison tooltip, say) showing the same unit
        function other:GetUnit() return "x", "mouseover" end
        function other:AddLine(text) table.insert(self.lines, text) end
        world.tooltipScripts.OnTooltipSetUnit(other)
        assert.are.equal(0, #other.lines)
        local bare = boot({ tooltipApi = "none", units = units })
        assert.are.equal(0, #bare.hover("mouseover"))
    end)

    it("says how old the data is, at login and in /lfgplus, once it's a week old, and keeps showing it", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" }, mouseover = { name = "Bright", realm = "Mend" } }
        local fresh, freshNs = boot({ clock = 1794096000 + 5 * 86400, units = units }) -- from 2026-11-07, six days on
        for _, line in ipairs(fresh.chat) do assert.is_nil(line:find("days old", 1, true)) end
        assert.are.equal("Data: 8 players, from 2026-11-07.", freshNs.DataStatusLine(freshNs.Now()))
        local week = boot({ clock = 1794096000 + 6 * 86400, units = units })
        assert.truthy(week.chat[#week.chat]:find("LFG+ data is 7 days old. Get the latest from lfg.plus/addon.", 1, true))
        local world, ns = boot({ clock = 1794096000 + 8 * 86400, units = units })
        local said = 0
        for _, line in ipairs(world.chat) do if line:find("LFG+ data is 9 days old.", 1, true) then said = said + 1 end end
        assert.are.equal(1, said)
        assert.are.equal("Data: 8 players, from 2026-11-07. LFG+ data is 9 days old. Get the latest from lfg.plus/addon.",
            ns.DataStatusLine(ns.Now()))
        assert.are.equal("Data: 8 players, from 2026-11-07.", ns.DataStatusLine()) -- without a time: just the data
        SlashCmdList.LFGPLUS("help")
        local listed = false
        for _, line in ipairs(world.chat) do if line:find("from 2026-11-07. LFG+ data is 9 days old.", 1, true) then listed = true end end
        assert.is_true(listed)
        assert.are.same(BRIGHT_MEND, world.texts(world.hover("mouseover"))) -- still shown
        -- The day arithmetic, leap days included, and data without a usable day.
        assert.are.same({ 0, 11017, 19782, 20103, 20764 }, { ns.DayNumber("1970-01-01"), ns.DayNumber("2000-03-01"),
            ns.DayNumber("2024-02-29"), ns.DayNumber("2025-01-15"), ns.DayNumber("2026-11-07") })
        assert.is_nil(ns.DayNumber("7 Nov 2026"))
        ns.data.day = nil
        assert.is_nil(ns.OldDataNote(ns.Now()))
        ns.data = nil
        assert.is_nil(ns.OldDataNote(ns.Now()))
    end)

    it("says why the data add-on didn't load, in words for each reason the client gives", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" } }
        local expected = {
            DISABLED = "Data: LFGPlus_Data_Forever_US is turned off. Turn it on in the AddOns list (at character select), then log in again.",
            INTERFACE_VERSION = "Data: LFGPlus_Data_Forever_US is out of date. Get the latest from lfg.plus/addon, CurseForge or Wago.",
            MISSING = "Data: not installed. Get LFGPlus_Data_Forever_US from lfg.plus/addon, CurseForge or Wago.",
            CORRUPT = "Data: LFGPlus_Data_Forever_US couldn't be loaded (CORRUPT). Install it again from lfg.plus/addon.",
        }
        for reason, line in pairs(expected) do
            local _, ns = boot({ noDataAddOn = reason, units = units })
            assert.are.equal(line, ns.DataStatusLine(ns.Now()))
        end
        local _, none = boot({ loadAddOnApi = "none", units = units })
        none.dataStatus.name = nil
        assert.are.equal("Data: the data add-on couldn't be loaded (NO_API). Install it again from lfg.plus/addon.", none.DataStatusLine())
    end)

    it("adds the LFG+ block to the group finder's listing and applicant tooltips, by name", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" } }
        local world, ns = boot({ groupFinder = "retail", units = units })
        world.listings[7] = { leaderName = "Bright Mend" }
        world.listings[8] = { leaderName = "Stranger Danger" }
        world.listings[9] = {} -- the leader's name isn't known yet
        world.applicants[3] = { "Sir Rocky", "Kaelwyn Stone" }
        local function shown(fn, ...)
            world.tooltip.lines = {}
            fn(...)
            return world.texts(world.tooltip.lines)
        end
        assert.are.same(with("Listing 7", BRIGHT_MEND), shown(LFGListUtil_SetSearchEntryTooltip, world.tooltip, 7))
        assert.are.same({ "Listing 8", " ", "LFG+ No endorsements yet" }, shown(LFGListUtil_SetSearchEntryTooltip, world.tooltip, 8))
        assert.are.same({ "Listing 9" }, shown(LFGListUtil_SetSearchEntryTooltip, world.tooltip, 9))
        assert.are.same({ "Listing 10" }, shown(LFGListUtil_SetSearchEntryTooltip, world.tooltip, 10)) -- no such listing
        local member = { memberIdx = 1, GetParent = function() return { applicantID = 3 } end }
        assert.are.same(with("Applicant", SIR_ROCKY), shown(LFGListApplicantMember_OnEnter, member))
        assert.are.same({ "Applicant" }, shown(LFGListApplicantMember_OnEnter, {})) -- not a member frame: no line, no error
        -- Hooked once, however often add-ons load.
        world.fire("ADDON_LOADED", "Blizzard_GroupFinder")
        assert.are.same(with("Listing 7", BRIGHT_MEND), shown(LFGListUtil_SetSearchEntryTooltip, world.tooltip, 7))
        local hooks = 0
        for _, e in ipairs(LFGPlusLog.entries) do if e.m:find("added the LFG+ line to the group finder's", 1, true) then hooks = hooks + 1 end end
        assert.are.equal(2, hooks)
    end)

    it("hooks the classic group finder's listings, also when it loads after us, and nothing on a client with neither", function()
        local units = { player = { name = "Kaelwyn", realm = "Stone" } }
        local world = boot({ units = units })
        world.listings[1] = { leaderName = "Moss Beard" }
        _G.LFGBrowseSearchEntryTooltip_UpdateAndShow = function(tooltip, resultID) tooltip:AddLine("Listing " .. resultID) end
        world.fire("ADDON_LOADED", "Blizzard_LookingForGroup")
        world.tooltip.lines = {}
        LFGBrowseSearchEntryTooltip_UpdateAndShow(world.tooltip, 1)
        assert.are.same(with("Listing 1", MOSS_BEARD), world.texts(world.tooltip.lines))
        local bare = boot({ groupFinder = "classic", units = units, without = { "hooksecurefunc" } })
        bare.tooltip.lines = {}
        LFGBrowseSearchEntryTooltip_UpdateAndShow(bare.tooltip, 1)
        assert.are.equal(1, #bare.tooltip.lines)
    end)

    it("detects WoW Forever by its project id first, whatever its interface number", function()
        _G.WOW_PROJECT_ID = 18
        local _, ns = boot({ interface = 120105, units = { player = { name = "Kaelwyn", realm = "Stone" } } })
        assert.are.equal(ns.GameVersions.FOREVER, ns.gameVersion)
        _G.WOW_PROJECT_CAMELOT = 19 -- the client's own constant, where it has one, says which id is Forever's
        assert.are.equal(ns.GameVersions.RETAIL, ns.DetectGameVersion())
        _G.WOW_PROJECT_ID = 19
        assert.are.equal(ns.GameVersions.FOREVER, ns.DetectGameVersion())
        _G.WOW_PROJECT_ID, _G.WOW_PROJECT_CAMELOT = 1, nil -- Retail's: the interface number decides
        assert.are.equal(ns.GameVersions.RETAIL, ns.DetectGameVersion())
        _G.WOW_PROJECT_ID = nil
    end)
end)

describe("the addon's files outside a client", function()
    it("load without CreateFrame, registering no events and no options page", function()
        _G.CreateFrame = nil
        local ns = loader.load({ "Core.lua", "Log.lua", "Window.lua", "Events.lua" })
        assert.is_function(ns.ToggleWindow)
        assert.is_nil(ns.optionsPanel)
    end)
end)
