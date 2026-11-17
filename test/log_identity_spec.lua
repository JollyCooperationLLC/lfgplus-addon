-- Log.lua (the persistent ring buffer) and Identity.lua (who a character is, per game version).
_G.bit = _G.bit or require("bit")
local loader = require("test.helpers.load_addon")

describe("Log", function()
    local ns
    before_each(function()
        _G.LFGPlusLog = nil
        _G.CreateFrame = nil
        _G.GetServerTime = function() return 1794096000 end
        _G.date = os.date
        ns = loader.load({ "Core.lua", "Log.lua" })
        ns.db = ns.ApplyDefaults({}, ns.DEFAULTS)
        ns.chat = {}
        ns.Print = function(t) table.insert(ns.chat, t) end
    end)

    it("keeps entries logged before ADDON_LOADED and starts a numbered session", function()
        ns.Log.Info("core", "early %d", 1)
        ns.Log.Start("1.2.3")
        assert.are.equal(1, LFGPlusLog.sessions)
        assert.are.equal("early 1", LFGPlusLog.entries[1].m)
        assert.are.equal(1, LFGPlusLog.entries[1].s)
        ns.Log.Start("1.2.3")
        assert.are.equal(2, LFGPlusLog.sessions)
    end)

    it("is a ring buffer of the newest 2000 entries", function()
        ns.Log.Start("x")
        for i = 1, 2100 do ns.Log.Info("t", "entry %d", i) end
        assert.are.equal(2000, #LFGPlusLog.entries)
        assert.are.equal("entry 2100", LFGPlusLog.entries[2000].m)
    end)

    it("masks anything that looks like a setup code", function()
        ns.Log.Start("x")
        ns.Log.Warn("t", "pasted LFG1:AAAAAAAAAAAAAAAAAAAAAQAByKYv1OoTPmpBqrMztX4jx1qjS5GDX8DfMIaL-cXHcVoiSg here")
        assert.are.equal("pasted LFG1:<redacted> here", LFGPlusLog.entries[#LFGPlusLog.entries].m)
    end)

    it("keeps debug entries only while debug is on", function()
        ns.Log.Start("x")
        local before = ns.Log.Count()
        ns.Log.Debug("t", "hidden")
        assert.are.equal(before, ns.Log.Count())
        ns.db.debug = true
        ns.Log.Debug("t", "kept")
        assert.are.equal(before + 1, ns.Log.Count())
    end)

    it("guards a function: passes its arguments and results, and logs an error with its stack instead of raising", function()
        ns.Log.Start("x")
        assert.are.equal(5, ns.Log.Guard("t", function(a, b) return a + b end, 2, 3))
        local wrapped = ns.Log.Wrap("t", function(x) error("boom " .. x) end)
        assert.has_no.errors(function() wrapped("now") end)
        local last = LFGPlusLog.entries[#LFGPlusLog.entries]
        assert.are.equal("E", last.l)
        assert.truthy(last.m:find("boom now", 1, true))
        assert.truthy(ns.chat[1]:find("/lfgplus log", 1, true)) -- told once
        wrapped("again")
        assert.are.equal(1, #ns.chat)
    end)

    it("formats recent entries for chat and never errors on bad format arguments", function()
        ns.Log.Start("x")
        ns.Log.Info("t", "%d items", "not a number")
        local lines = ns.Log.Recent(2)
        assert.are.equal(2, #lines)
        assert.truthy(lines[2]:find("[t]", 1, true))
        ns.Log.Clear()
        assert.are.equal(0, ns.Log.Count())
    end)

    it("stamps entries with the system clock on a client without GetServerTime", function()
        _G.GetServerTime = nil
        ns.Log.Start("x")
        local entry = ns.Log.Info("t", "no server time")
        assert.is_number(entry.t)
        assert.truthy(math.abs(entry.t - os.time()) < 60)
    end)

    it("clears entries logged before the saved log exists", function()
        ns.Log.Info("t", "early")
        assert.are.equal(1, ns.Log.Count())
        ns.Log.Clear()
        assert.are.equal(0, ns.Log.Count())
        assert.is_nil(LFGPlusLog)
    end)
end)

describe("Identity", function()
    local ns
    before_each(function()
        _G.GetNormalizedRealmName = function() return "TwistingNether" end
        _G.GetCurrentRegion = function() return 3 end
        ns = loader.load({ "Core.lua", "Log.lua", "Identity.lua" })
    end)

    it("reads Forever's (first name, surname) as one realmless name", function()
        ns.gameVersion = ns.GameVersions.FOREVER
        local id = ns.IdentityFromParts("Middle", "Foot", "Player-4395-00000007")
        assert.are.equal("Middle Foot", id.name)
        assert.are.equal("", id.realm)
        assert.are.equal("middle foot", id.key)
        assert.are.equal("Middle Foot", ns.WhisperTarget(id))
        assert.truthy(ns.SameCharacter(id, ns.IdentityFromSender("Middle Foot")))
    end)

    it("reads (name, realm) elsewhere, filling in our realm when it's missing", function()
        ns.gameVersion = ns.GameVersions.RETAIL
        local away = ns.IdentityFromParts("Thrallina", "Whitemane")
        assert.are.equal("Thrallina-Whitemane", ns.WhisperTarget(away))
        local home = ns.IdentityFromParts("Brightmend", nil)
        assert.are.equal("TwistingNether", home.realm)
        assert.truthy(ns.SameCharacter(away, ns.IdentityFromSender("Thrallina-Whitemane")))
        assert.truthy(ns.SameCharacter(home, ns.IdentityFromSender("Brightmend")))
        assert.is_false(ns.SameCharacter(away, home))
    end)

    it("spells a cross-realm realm the way keys and whispers do: no spaces or hyphens, apostrophes kept", function()
        ns.gameVersion = ns.GameVersions.RETAIL
        for realm, spelled in pairs({ ["Aerie Peak"] = "AeriePeak", ["Azjol-Nerub"] = "AzjolNerub", ["Mal'Ganis"] = "Mal'Ganis" }) do
            local id = ns.IdentityFromParts("Thrallina", realm)
            assert.are.same({ spelled, "thrallina-" .. spelled:lower() }, { id.realm, id.key })
            assert.are.equal("Thrallina-" .. spelled, ns.WhisperTarget(id))
            assert.truthy(ns.SameCharacter(id, ns.IdentityFromSender("Thrallina-" .. spelled)))
            assert.truthy(ns.SameCharacter(id, ns.IdentityFromSender("Thrallina-" .. realm))) -- however a sender spells it
        end
        -- Our own realm from GetRealmName while the client has no normalized one yet, and none at all without either.
        _G.GetNormalizedRealmName = nil
        _G.GetRealmName = function() return "Aerie Peak" end
        assert.are.equal("AeriePeak", ns.IdentityFromParts("Brightmend", nil).realm)
        _G.GetRealmName = nil
        assert.are.equal("", ns.IdentityFromParts("Brightmend", nil).realm)
    end)

    it("maps the client's region numbers to ours, and has none for China", function()
        assert.are.equal(2, ns.RegionId()) -- client 3 is EU, our 2
        _G.GetCurrentRegion = function() return 5 end
        assert.is_nil(ns.RegionId())
    end)

    it("has no identity for an empty name or sender", function()
        ns.gameVersion = ns.GameVersions.FOREVER
        assert.is_nil(ns.IdentityFromParts(nil, "Foot"))
        assert.is_nil(ns.IdentityFromParts("", "Foot"))
        assert.is_nil(ns.IdentityFromSender(nil))
        assert.is_nil(ns.IdentityFromSender(""))
    end)

    it("keeps a unit's name but drops a GUID the client hides (Midnight secret values)", function()
        local SECRET = {}
        _G.issecretvalue = function(v) return v == SECRET end
        _G.UnitExists = function() return true end
        _G.UnitIsPlayer = function() return true end
        _G.UnitName = function() return "Middle", "Foot" end
        _G.UnitGUID = function() return SECRET end
        ns.gameVersion = ns.GameVersions.FOREVER
        local id = ns.UnitIdentity("target")
        assert.are.equal("Middle Foot", id.name)
        assert.is_nil(id.guid)
        _G.issecretvalue, _G.UnitExists, _G.UnitIsPlayer, _G.UnitName, _G.UnitGUID = nil, nil, nil, nil, nil
    end)
end)
