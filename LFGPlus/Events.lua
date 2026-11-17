-- Wires the client's events to the addon. Every handler runs inside Log.Wrap, so an error is logged with its stack
-- instead of reaching the player. ADDON_LOADED stays in Core.lua (saved variables must exist first).

local _, ns = ...

if not CreateFrame then return end

local handlers = {}

handlers.PLAYER_LOGIN = function()
    ns.player = nil -- re-read our identity now that the client knows it
    local me = ns.PlayerIdentity()
    ns.Log.Info("core", "logged in as %s (realm %q, guid %s), game version %s, region %s",
        tostring(me and me.name), tostring(me and me.realm), tostring(me and me.guid), tostring(ns.gameVersion), tostring(ns.RegionId()))
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        ns.Log.Info("comm", "registered prefix %s: %s", ns.ADDON_PREFIX, tostring(C_ChatInfo.RegisterAddonMessagePrefix(ns.ADDON_PREFIX)))
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(ns.ADDON_PREFIX)
    end
    ns.LoadDataAddon()
    local oldData = ns.OldDataNote(ns.Now())
    if oldData then ns.Print(oldData) end
    ns.RegisterUnitMenus()
    ns.HookGroupFinder()
    ns.CollectDiagnostics()
    -- Said once, at login, rather than failing quietly at every endorsement.
    if ns.IsTrialAccount() then ns.Print(ns.TRIAL_TEXT) end
    ns.PruneRecords(ns.Now())
    ns.RestoreRun()
    ns.UpdateRunForZone()
end

handlers.PLAYER_ENTERING_WORLD = function()
    -- A loading screen can swallow ENCOUNTER_END (a wipe, a disconnect, leaving mid-fight), which would hold messages
    -- and popups forever: ask the client where it can tell, else assume no encounter is on.
    local inEncounter = (IsEncounterInProgress and IsEncounterInProgress()) or false
    if ns.commState.inEncounter and not inEncounter then ns.Log.Info("runs", "no encounter in progress after a loading screen") end
    ns.commState.inEncounter = inEncounter
    ns.UpdateRunForZone()
    ns.ResumeSending()
    ns.FlushDeferred()
end

-- Blizzard's group finder may load after us: hook its tooltips whenever another add-on loads (each hook happens once).
handlers.ADDON_LOADED = function() ns.HookGroupFinder() end

handlers.ZONE_CHANGED_NEW_AREA = function() ns.UpdateRunForZone() end

handlers.GROUP_ROSTER_UPDATE = function()
    ns.LogGroupMembers()
    ns.OnGroupChanged()
end

handlers.CHAT_MSG_ADDON = function(prefix, message, channel, sender)
    if prefix ~= ns.ADDON_PREFIX then return end
    ns.OnAddonMessage(message, sender, channel) -- which channels are listened to, and for what, is decided there
end

handlers.ENCOUNTER_START = function(encounterId, encounterName)
    ns.commState.inEncounter = true
    ns.Log.Info("runs", "encounter %s (%s) started", tostring(encounterName), tostring(encounterId))
end

handlers.ENCOUNTER_END = function(...)
    ns.commState.inEncounter = false
    ns.OnEncounterEnd(...)
    ns.ResumeSending()
    ns.FlushDeferred()
end

handlers.PLAYER_REGEN_ENABLED = function()
    ns.ResumeSending()
    ns.FlushDeferred()
end

-- Midnight's addon-message lockdown (also on WoW Forever) changed: what it held can go out once it lifts.
-- The client fires this for every kind of restriction, often several times a minute, so only a change to messaging
-- is logged.
handlers.ADDON_RESTRICTION_STATE_CHANGED = function()
    local locked = ns.MessagingLocked()
    if locked ~= ns.commState.messagingLocked then
        ns.Log.Info("comm", "addon messaging %s", locked and "locked down" or "unlocked")
        ns.commState.messagingLocked = locked
    end
    ns.ResumeSending()
end

-- Run completion signals. Which of these Forever fires is one of the things the log will tell us.
handlers.LFG_COMPLETION_REWARD = function() ns.CompleteRun("LFG_COMPLETION_REWARD") end
handlers.SCENARIO_COMPLETED = function() ns.CompleteRun("SCENARIO_COMPLETED") end
handlers.CHALLENGE_MODE_COMPLETED = function() ns.CompleteRun("CHALLENGE_MODE_COMPLETED") end

-- The client says so when a whisper target is offline or doesn't exist; useful when an ack never comes.
handlers.CHAT_MSG_SYSTEM = function(text)
    if type(text) == "string" and (text:find("not currently playing", 1, true) or text:find("No player named", 1, true)) then
        ns.Log.Info("comm", "system: %s", text)
    end
end

handlers.PLAYER_LOGOUT = function()
    ns.Log.Info("core", "logging out: %d records held, %d messages still queued", #ns.db.records, ns.QueuedMessages())
    ns.SaveRun()
end

local frame = CreateFrame("Frame")
for event, fn in pairs(handlers) do
    -- Some events don't exist on every client (CHALLENGE_MODE_COMPLETED on classic ones); skip those quietly.
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then ns.Log.Info("core", "event %s isn't available on this client", event) end
    handlers[event] = ns.Log.Wrap("event:" .. event, fn)
end
frame:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn then fn(...) end
end)
