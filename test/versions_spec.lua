-- The whole addon booted as each game version's client: the version it detects, the data add-on it
-- loads, who its group members are (with their realm, or WoW Forever's surname) and how it whispers them. And Midnight's
-- addon-message lockdown, which holds messages until it lifts (also on WoW Forever).
local stubs = require("test.helpers.wow_stubs")

local CLIENTS = {
    { label = "Retail", interface = 120105, version = 10, folder = "LFGPlus_Data_Retail_US" },
    { label = "Classic (Mists of Pandaria)", interface = 50504, version = 20, folder = "LFGPlus_Data_Classic_US" },
    { label = "Classic Era", interface = 11509, version = 30, folder = "LFGPlus_Data_ClassicEra_US" },
    { label = "WoW Forever", interface = 16001, version = 40, folder = "LFGPlus_Data_Forever_US", realmless = true },
    { label = "TBC Anniversary", interface = 20506, version = 50, folder = "LFGPlus_Data_Anniversary_US" },
}

local function boot(interface)
    _G.LFGPlusDB = nil
    local world = stubs.install({
        interface = interface,
        realm = "Twisting Nether",
        units = {
            player = { name = "Middle", realm = interface >= 16000 and interface < 17000 and "Foot" or nil, guid = "Player-1-00000007" },
            party1 = { name = "Corvina", realm = "Ashby", guid = "Player-1-0A1B2C3D" },
        },
    })
    local ns = world.loadAddon()
    world.fireAddonLoaded()
    world.fire("PLAYER_LOGIN")
    return world, ns
end

describe("the addon on every game version", function()
    after_each(function() _G.LFGPlusDB = nil end)

    for _, client in ipairs(CLIENTS) do
        it("boots as " .. client.label .. ": its version, its data add-on, and names with or without realms", function()
            local world, ns = boot(client.interface)
            assert.are.equal(client.version, ns.gameVersion)
            assert.are.equal(client.folder, ns.DataAddonName(ns.gameVersion, ns.RegionId()))
            local corvina = ns.UnitIdentity("party1")
            local me = ns.PlayerIdentity()
            if client.realmless then
                -- WoW Forever: the second name is the surname, and whispers go to "First Surname".
                assert.are.same({ "Corvina Ashby", "", "corvina ashby" }, { corvina.name, corvina.realm, corvina.key })
                assert.are.equal("Corvina Ashby", ns.WhisperTarget(corvina))
                assert.are.same({ "Middle Foot", "" }, { me.name, me.realm })
            else
                -- Everywhere else the second name is the realm, and our own is the client's normalized realm.
                assert.are.same({ "Corvina", "Ashby", "corvina-ashby" }, { corvina.name, corvina.realm, corvina.key })
                assert.are.equal("Corvina-Ashby", ns.WhisperTarget(corvina))
                assert.are.same({ "Middle", "TwistingNether", "middle-twistingnether" }, { me.name, me.realm, me.key })
            end
            local errors = {}
            for _, e in ipairs(LFGPlusLog.entries) do if e.l == "E" then errors[#errors + 1] = e.m end end
            assert.are.same({}, errors)
            assert.is_true(#world.chat > 0) -- the loaded line
        end)
    end

    it("holds messages while addon messages are locked down, and sends them in order once it lifts", function()
        local world, ns = boot(120105)
        world.lockdown = true
        assert.is_true(ns.Send("Q:one", "Corvina-Ashby"))
        assert.is_true(ns.Send("Q:two", "Corvina-Ashby"))
        assert.are.same({}, world.sent)
        assert.are.equal(2, ns.QueuedMessages())
        world.lockdown = false
        world.fire("ADDON_RESTRICTION_STATE_CHANGED")
        world.advance(5)
        local sent = {}
        for _, m in ipairs(world.sent) do sent[#sent + 1] = m.message end
        assert.are.same({ "Q:one", "Q:two" }, sent)
    end)

    it("logs the lockdown only when it starts or lifts, not every time the client's restrictions change", function()
        local world = boot(16001)
        local function lines()
            local out = {}
            for _, e in ipairs(LFGPlusLog.entries) do
                if e.m:find("addon messaging", 1, true) then out[#out + 1] = e.m end
            end
            return out
        end
        local before = #lines()
        for _, locked in ipairs({ false, false, true, true, false, false }) do
            world.lockdown = locked
            world.fire("ADDON_RESTRICTION_STATE_CHANGED")
        end
        local logged = lines()
        assert.are.same({ "addon messaging unlocked", "addon messaging locked down", "addon messaging unlocked" },
            { logged[before + 1], logged[before + 2], logged[before + 3] })
        assert.are.equal(before + 3, #logged)
    end)

    it("keeps a message the client refused because the lockdown began just then, first in line", function()
        local world, ns = boot(16001)
        world.refuseNextSend = true
        assert.is_true(ns.Send("Q:held", "Corvina Ashby"))
        assert.are.same({}, world.sent)
        assert.are.equal(1, ns.QueuedMessages())
        world.fire("ADDON_RESTRICTION_STATE_CHANGED")
        assert.are.equal("Q:held", world.sent[1].message)
        assert.are.equal(0, ns.QueuedMessages())
    end)

    it("treats a client without the lockdown API as never locked down", function()
        local world, ns = boot(11509)
        _G.C_ChatInfo.InChatMessagingLockdown = nil
        assert.is_false(ns.MessagingLocked())
        ns.Send("Q:era", "Corvina-Ashby")
        assert.are.equal("Q:era", world.sent[1].message)
    end)
end)
