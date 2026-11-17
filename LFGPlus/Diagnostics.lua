-- Records what this client actually reports, so facts we can't look up (WoW Forever's GUID format,
-- what UnitName/GetRealmName return, addon-message behaviour) arrive in the log the first time someone plays.
-- Snapshot at login into LFGPlusLog.diagnostics, plus one log line per group member the first time we see them.
-- `/lfgplus diag` takes a fresh snapshot and prints a summary.

local _, ns = ...

local function call(fn, ...)
    if type(fn) ~= "function" then return "<missing>" end
    local results = { pcall(fn, ...) }
    if not results[1] then return "<error: " .. tostring(results[2]) .. ">" end
    for i = 2, #results do results[i] = tostring(results[i]) end
    return table.concat(results, " | ", 2)
end

local function field(t, key)
    return t and t[key]
end

--- Takes a snapshot of client facts. Returns it (a flat table of strings) and stores it in LFGPlusLog.diagnostics.
function ns.CollectDiagnostics()
    local d = {
        at = tostring(GetServerTime and GetServerTime() or 0),
        addonVersion = tostring(ns.VERSION),
        gameVersion = tostring(ns.gameVersion),
        buildInfo = call(GetBuildInfo),
        projectId = tostring(WOW_PROJECT_ID),
        -- WoW Forever's project id, from web research, not yet checked in game: 18, if the constant exists at all.
        projectCamelot = tostring(WOW_PROJECT_CAMELOT),
        locale = call(GetLocale),
        currentRegion = call(GetCurrentRegion),
        regionId = tostring(ns.RegionId()),
        unitName = call(UnitName, "player"),
        unitFullName = call(UnitFullName, "player"),
        unitNameUnmodified = call(UnitNameUnmodified, "player"),
        getUnitName = call(GetUnitName, "player", true),
        realmName = call(GetRealmName),
        normalizedRealm = call(GetNormalizedRealmName),
        realmId = call(GetRealmID),
        guid = call(UnitGUID, "player"),
        playerInfoByGuid = call(GetPlayerInfoByGUID, UnitGUID and UnitGUID("player")),
        serverTime = call(GetServerTime),
        instance = call(GetInstanceInfo),
        bestMap = call(field(C_Map, "GetBestMapForUnit"), "player"),
        addonMessageApi = (C_ChatInfo and C_ChatInfo.SendAddonMessage) and "C_ChatInfo" or (SendAddonMessage and "global" or "<missing>"),
        -- Midnight's addon-message lockdown, and the accounts that can't send addon messages at all.
        messagingLockdown = call(field(C_ChatInfo, "InChatMessagingLockdown")),
        trialAccount = call(IsTrialAccount),
        veteranTrialAccount = call(IsVeteranTrialAccount),
        battleNetApi = (C_BattleNet and "C_BattleNet" or "<missing>"),
        guildApi = (IsInGuild and call(IsInGuild) or "<missing>"),
        linked = tostring(ns.IsLinked and ns.IsLinked() or false),
        data = ns.DataStatusLine and ns.DataStatusLine() or "<none>",
    }
    if type(LFGPlusLog) == "table" then LFGPlusLog.diagnostics = d end
    for _, key in ipairs({ "buildInfo", "projectId", "projectCamelot", "currentRegion", "unitName", "unitFullName", "getUnitName",
        "realmName", "normalizedRealm", "realmId", "guid", "instance", "bestMap", "addonMessageApi", "messagingLockdown",
        "trialAccount", "veteranTrialAccount" }) do
        ns.Log.Info("diag", "%s = %s", key, d[key])
    end
    return d
end

-- Group members we've already logged this session, by GUID or name.
local seen = {}

--- Logs each new group member's raw name values and GUID once per session: the GUID format on Forever.
function ns.LogGroupMembers()
    local units = {}
    if IsInRaid and IsInRaid() then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        if UnitExists and UnitExists(unit) and UnitIsPlayer(unit) then
            local guid = UnitGUID and UnitGUID(unit)
            local first, second = UnitName(unit)
            local id = tostring(guid or first)
            if not seen[id] then
                seen[id] = true
                ns.Log.Info("diag", "member %s: UnitName = %s | %s, GUID = %s, GetUnitName = %s",
                    unit, tostring(first), tostring(second), tostring(guid), call(GetUnitName, unit, true))
            end
        end
    end
end
