-- Notices when a run ends, so the post-run prompt can list the group.
--
-- A run starts when we enter a party, raid or scenario instance. It ends on a completion event (LFG reward, scenario
-- or keystone complete), or, after at least one boss kill, once we're done with the instance: on entering another
-- instance, on leaving the group (or the group disbanding) while outside, or after OUTSIDE_LIMIT seconds outside.
-- Stepping out isn't the end by itself: a player who died and released runs back as a ghost, and anyone may step out
-- to repair; coming back in keeps the run. Everyone seen in the group during the run is offered, even if they've left
-- by the end. An unfinished run is saved at logout (a /reload too) and picked up again back in the same instance.
-- Every step is logged, because how each client reports these events (WoW Forever especially) is still being learned.

local _, ns = ...

local RUN_TYPES = { party = true, raid = true, scenario = true }
local OUTSIDE_LIMIT = 600     -- seconds outside the instance before the run ends
local DEAD_RECHECK = 60       -- still dead or a ghost when that time is up: look again this much later
local RESTORE_WINDOW = 1800   -- a run saved at logout is picked up again only this soon after (a /reload, a relog)

ns.run = nil

--- Identities of everyone in the group except us.
function ns.GroupIdentities()
    local units = {}
    if IsInRaid and IsInRaid() then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    local me = ns.PlayerIdentity()
    local out = {}
    for _, unit in ipairs(units) do
        local identity = ns.UnitIdentity(unit)
        if identity and not ns.SameCharacter(identity, me) then out[#out + 1] = identity end
    end
    return out
end

local function remember(run)
    for _, identity in ipairs(ns.GroupIdentities()) do
        if not run.members[identity.key] then
            run.members[identity.key] = identity
            run.order[#run.order + 1] = identity.key
        end
    end
end

local function after(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, ns.Log.Wrap("timer:runs", fn)) end
end

local function isDead()
    return (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or false
end

local function inGroup()
    return (IsInGroup and IsInGroup()) or false
end

local function startRun(instanceId, name, instanceType)
    ns.run = { instanceId = instanceId, name = name, kind = instanceType, started = ns.Now(), kills = 0, members = {}, order = {} }
    remember(ns.run)
    ns.Log.Info("runs", "run started: %s (%s, instance %s), %d in group", tostring(name), tostring(instanceType),
        tostring(instanceId), #ns.run.order)
end

--- Ends the current run and offers the prompt. `reason` is logged.
function ns.CompleteRun(reason)
    local run = ns.run
    if not run or run.completed then return end
    run.completed = true
    remember(run)
    local members = {}
    for _, key in ipairs(run.order) do members[#members + 1] = run.members[key] end
    ns.Log.Info("runs", "run ended (%s): %s, %d boss kills, %d players, %ds", reason, tostring(run.name), run.kills,
        #members, ns.Now() - run.started)
    members = ns.NotYetEndorsed(members)
    if #members == 0 then return end
    if ns.IsTrialAccount() then
        ns.Log.Info("runs", "trial account: no prompt (it can't send addon messages)")
        return
    end
    if not ns.db.promptAfterRuns then
        ns.Log.Info("runs", "prompt is off; not shown")
        return
    end
    if ns.ShowPrompt then ns.ShowPrompt(members, run.name) end
end

--- Ends the run we stepped out of, and forgets it.
local function endOutside(reason)
    ns.CompleteRun(reason)
    ns.run = nil
end

--- OUTSIDE_LIMIT seconds after we left: ends the run if we're still out since then, unless we're dead (a ghost may
-- still be on its way back), when it looks again DEAD_RECHECK seconds later.
local function outsideTimeUp(run, leftAt)
    if ns.run ~= run or run.leftAt ~= leftAt then return end -- back inside, or over some other way
    if isDead() then
        ns.Log.Info("runs", "still outside %s, dead; looking again in %ds", tostring(run.name), DEAD_RECHECK)
        after(DEAD_RECHECK, function() outsideTimeUp(run, leftAt) end)
        return
    end
    endOutside(("%d minutes outside"):format(OUTSIDE_LIMIT / 60))
end

--- On entering the world or changing zone: starts, keeps or ends runs.
function ns.UpdateRunForZone()
    local inInstance, instanceType = false, nil
    if IsInInstance then inInstance, instanceType = IsInInstance() end
    local run = ns.run
    if inInstance and RUN_TYPES[instanceType] then
        local name, _, _, _, _, _, _, instanceId = GetInstanceInfo()
        if run and not run.completed and run.instanceId == instanceId then
            if run.leftAt then
                run.leftAt = nil
                ns.Log.Info("runs", "back in %s: the run goes on", tostring(run.name))
            end
            return
        end
        if run and not run.completed and run.kills > 0 then ns.CompleteRun("entered another instance") end
        startRun(instanceId, name, instanceType)
    elseif run and (run.completed or run.kills == 0) then
        if not run.completed then ns.Log.Info("runs", "left %s without a boss kill; no prompt", tostring(run.name)) end
        ns.run = nil
    elseif run and not run.leftAt then
        -- Outside after a kill. Out of the group too, and alive: the run is over. Otherwise it may go on.
        if not isDead() and not inGroup() then return endOutside("left the instance and the group") end
        run.leftAt = ns.Now()
        local leftAt = run.leftAt
        ns.Log.Info("runs", "left %s (dead: %s); the run ends in %d minutes unless we come back", tostring(run.name),
            tostring(isDead()), OUTSIDE_LIMIT / 60)
        after(OUTSIDE_LIMIT, function() outsideTimeUp(run, leftAt) end)
    end
end

function ns.OnEncounterEnd(encounterId, encounterName, _, _, success)
    ns.Log.Info("runs", "encounter %s (%s) ended, success %s", tostring(encounterName), tostring(encounterId), tostring(success))
    if ns.run and success == 1 then
        ns.run.kills = ns.run.kills + 1
        remember(ns.run)
    end
end

function ns.OnGroupChanged()
    local run = ns.run
    if not run or run.completed then return end
    remember(run)
    -- Outside, and the group is gone (we left it, or it disbanded): nothing to come back to.
    if run.leftAt and not inGroup() then endOutside("left the group") end
end

--- Saves an unfinished run for the next login (PLAYER_LOGOUT, which a /reload fires too).
function ns.SaveRun()
    ns.db.run = nil
    local run = ns.run
    if run and not run.completed then
        run.savedAt = ns.Now()
        ns.db.run = run
    end
end

--- At login: picks up the run saved at logout when we're back in its instance soon after (a /reload, a quick relog),
-- so its boss kills and players aren't lost. Called before UpdateRunForZone.
function ns.RestoreRun()
    local saved = ns.db.run
    ns.db.run = nil
    if type(saved) ~= "table" or type(saved.members) ~= "table" or type(saved.order) ~= "table"
        or type(saved.kills) ~= "number" or type(saved.started) ~= "number" then
        return
    end
    local inInstance, instanceType = false, nil
    if IsInInstance then inInstance, instanceType = IsInInstance() end
    local instanceId = inInstance and RUN_TYPES[instanceType] and select(8, GetInstanceInfo())
    if instanceId ~= saved.instanceId or ns.Now() - (tonumber(saved.savedAt) or 0) > RESTORE_WINDOW then
        ns.Log.Info("runs", "the run saved in %s isn't picked up: we're elsewhere, or it's too old", tostring(saved.name))
        return
    end
    saved.savedAt, saved.leftAt = nil, nil
    ns.run = saved
    ns.Log.Info("runs", "picked up the run in %s again: %d boss kills, %d players", tostring(saved.name), saved.kills, #saved.order)
end
