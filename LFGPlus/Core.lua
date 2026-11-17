-- LFG+ addon: core namespace, saved variables and game-version detection.
-- Every file receives the same private table `ns` from the client (`local addonName, ns = ...`).

local addonName, ns = ...

ns.ADDON_NAME = addonName
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(addonName, "Version"))
    or "dev"

-- Game versions, matching the site's numbers. Do not change them.
ns.GameVersions = {
    RETAIL = 10,
    CLASSIC = 20,
    CLASSIC_ERA = 30,
    FOREVER = 40,
    ANNIVERSARY = 50,
}

-- WoW Forever's WOW_PROJECT_ID (WOW_PROJECT_CAMELOT), from web research rather than an in-game check.
local FOREVER_PROJECT_ID = 18

--- Which game version an interface number (the TOC number, 4th value of GetBuildInfo) belongs to. Pure, so specs can
-- call it. WoW Forever's interface numbers are 1.60.x.
function ns.GameVersionForInterface(toc)
    toc = tonumber(toc) or 0
    if toc >= 100000 then return ns.GameVersions.RETAIL end
    if toc >= 16000 and toc < 17000 then return ns.GameVersions.FOREVER end
    if toc >= 11000 and toc < 12000 then return ns.GameVersions.CLASSIC_ERA end
    -- TBC Anniversary (2.5.x) is its own version, with its own realms; progression Classic is everything else.
    if toc >= 20000 and toc < 30000 then return ns.GameVersions.ANNIVERSARY end
    return ns.GameVersions.CLASSIC
end

--- The client's game version: WoW Forever by its project id where the client has one, else by interface number.
function ns.DetectGameVersion()
    if WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or FOREVER_PROJECT_ID) then
        return ns.GameVersions.FOREVER
    end
    local _, _, _, toc = GetBuildInfo()
    return ns.GameVersionForInterface(toc)
end

-- Saved variables start nil on first load; fill in defaults without overwriting what the player set.
local DEFAULTS = {
    setupCode = nil,      -- pasted from lfg.plus; never printed
    promptAfterRuns = true,
    toastSound = true,
    thankWhisper = false, -- opt-in: whisper a thank-you to each player you endorse
    debug = false,        -- /lfgplus debug: verbose log entries, echoed to chat
    lastCounter = 0,      -- the last record counter used (Endorse.lua)
    -- How to answer endorsement requests, per relationship: "auto" (default) or "ask".
    ack = { group = "auto", guild = "auto", friends = "auto", others = "auto" },
    dailyCounter = { day = nil, used = 0 },
    records = {},         -- given and received endorsements, for /lfgplus upload
    -- Copies of other players' records heard on the group channel, as { text, at }, so our upload delivers them too
    -- Real and quiet records are carried alike.
    carried = {},
    -- Everyone this install has endorsed, by character key: { at, tags, proven }. Never pruned: one endorsement per
    -- player, ever, unless their addon never confirmed it. Real and quiet alike, so nothing here tells them apart.
    endorsed = {},
    -- Every record and carried copy gets the next number when stored or replaced. "I uploaded these" in the upload box
    -- sets uploadedSeq (nil until then): copies numbered up to it no longer count as waiting.
    lastSeq = 0,
    -- Endorsements whose ack didn't come in time, by counter, kept a day so a late ack can still prove them.
    lateAcks = {},
    -- The minimap button; LibDBIcon reads and writes this table itself (minimapPos, hide, showInCompartment).
    minimap = { hide = false, showInCompartment = true },
}

ns.DEFAULTS = DEFAULTS

function ns.ApplyDefaults(db, defaults)
    for key, value in pairs(defaults) do
        if db[key] == nil then
            if type(value) == "table" then
                db[key] = {}
                ns.ApplyDefaults(db[key], value)
            else
                db[key] = value
            end
        end
    end
    return db
end

--- The server's clock, in Unix seconds.
function ns.Now()
    return GetServerTime and GetServerTime() or os.time()
end

function ns.Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff1eff00LFG+|r " .. text)
end

if CreateFrame then
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", function(self, event, loaded)
        if loaded ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        LFGPlusDB = ns.ApplyDefaults(LFGPlusDB or {}, DEFAULTS)
        ns.db = LFGPlusDB
        ns.gameVersion = ns.DetectGameVersion()
        if ns.Log then ns.Log.Start(ns.VERSION) end
        local load = function() if ns.LoadAccount then ns.LoadAccount() end end
        if ns.Log then ns.Log.Guard("core", load) else load() end
        if ns.SetupMinimap then ns.Log.Guard("ui", ns.SetupMinimap) end
        ns.Print(("v%s loaded. Type /lfgplus for options."):format(ns.VERSION))
    end)
end
