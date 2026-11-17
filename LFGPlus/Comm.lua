-- Addon messages: one prefix, whispered to one player at a time; a finished record also goes to the group channel
-- once.
--
-- Sending is queued: nothing goes out in combat or during a boss encounter, and the queue
-- drains one message every SEND_INTERVAL seconds, or every SLOW_INTERVAL after a burst, so we stay below the client's
-- throttle; a message the client throttles anyway waits its turn again. Every send logs the client's result code,
-- because addon-message rules differ between clients (Forever has reported "InvalidChannel").

local _, ns = ...

ns.ADDON_PREFIX = "LFGPLUS"
local SEND_INTERVAL = 0.3
local SLOW_INTERVAL = 1             -- after BURST messages within BURST_WINDOW seconds
local BURST, BURST_WINDOW = 8, 10
local RETRY_AFTER = 1               -- seconds before a throttled message is tried again
local MAX_QUEUE = 50
ns.MAX_MESSAGE_BYTES = 255          -- the client's limit for one addon message
local OFFLINE_WINDOW = 30           -- seconds a whisper target's "No player named" notice is shown only once

local queue = {}
local draining = false
local recentSends = {}  -- when the last messages went out, for the burst limit
local whispered = {}    -- lower-cased whisper target -> when we last whispered it
local offline = {}      -- lower-cased whisper target -> the "No player named" notice shown for it: { at, line }
ns.commState = { inEncounter = false }

local function inCombat()
    return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

--- True when messages and popups must wait: in combat or during a boss encounter.
function ns.IsBusy()
    return inCombat() or ns.commState.inEncounter
end

-- C_ChatInfo.SendAddonMessage's answers (Enum.SendAddonMessageResult, where the client has it): refused for now by
-- Midnight's lockdown, or throttled (too many addon messages, or too many on one channel).
local RESULTS = (Enum and Enum.SendAddonMessageResult) or {}
local ADDON_MESSAGE_LOCKDOWN = RESULTS.AddOnMessageLockdown or 11
local THROTTLED = { [RESULTS.AddonMessageThrottle or 3] = true, [RESULTS.ChannelThrottle or 8] = true }

--- Seconds, with fractions where the client has them (GetTime), for spacing messages.
local function clock()
    return (GetTime and GetTime()) or (GetServerTime and GetServerTime()) or 0
end

--- True while the client refuses addon messages: Midnight's lockdown during boss encounters, active Mythic+ runs and
-- PvP, also on WoW Forever. Messages wait for it; popups don't.
function ns.MessagingLocked()
    return (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) or false
end

-- The channels a group hears. Only finished records ("R:") are accepted from them; the handshake is whispered.
local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

--- The channel that reaches the group we're in: "INSTANCE_CHAT" in an instance (LFG) group, "RAID" in a raid, "PARTY"
-- in a party; nil when not grouped. The instance group is asked about first: inside one, "RAID" and "PARTY" address
-- the group we came from, not the one we're playing with.
function ns.GroupChannel()
    if not IsInGroup or not IsInGroup() then return nil end
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid and IsInRaid() then return "RAID" end
    return "PARTY"
end

--- Sends one message now: a whisper to `target`, or to a group channel when `channel` is given (`target` is then
-- nil). Overridable in specs. Returns the client's result (true/false, or a result enum).
function ns.SendRaw(message, target, channel)
    channel = channel or "WHISPER"
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return C_ChatInfo.SendAddonMessage(ns.ADDON_PREFIX, message, channel, target)
    elseif SendAddonMessage then
        return SendAddonMessage(ns.ADDON_PREFIX, message, channel, target)
    end
    return "no-api"
end

local function after(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, ns.Log.Wrap("timer:comm", fn)) else fn() end
end

--- How long to wait before the next message: longer once BURST messages went out within BURST_WINDOW seconds.
local function nextInterval(now)
    local recent = {}
    for _, t in ipairs(recentSends) do if now - t < BURST_WINDOW then recent[#recent + 1] = t end end
    recent[#recent + 1] = now
    recentSends = recent
    return #recent >= BURST and SLOW_INTERVAL or SEND_INTERVAL
end

local function drain()
    if #queue == 0 then draining = false; return end
    -- Resumed by PLAYER_REGEN_ENABLED, ENCOUNTER_END or ADDON_RESTRICTION_STATE_CHANGED.
    if ns.IsBusy() or ns.MessagingLocked() then draining = false; return end
    local item = table.remove(queue, 1)
    local result = ns.SendRaw(item.message, item.target, item.channel)
    if result == ADDON_MESSAGE_LOCKDOWN then
        -- The lockdown began between our check and the send: keep the message, first in line, for when it lifts.
        table.insert(queue, 1, item)
        draining = false
        ns.Log.Info("comm", "held %s for %s: addon messages are locked down", item.message:sub(1, 2), item.to)
        return
    end
    if THROTTLED[result] then
        -- The client is rationing addon messages: keep this one first in line and try again shortly.
        table.insert(queue, 1, item)
        ns.Log.Info("comm", "throttled %s to %s, result %s; trying again in %ds", item.message:sub(1, 2), item.to,
            tostring(result), RETRY_AFTER)
        after(RETRY_AFTER, drain)
        return
    end
    ns.Log.Info("comm", "sent %s to %s (%d bytes), result %s", item.message:sub(1, 2), item.to, #item.message, tostring(result))
    local now = clock()
    if not item.channel then whispered[item.to:lower()] = now end
    if item.onDequeued then item.onDequeued() end
    after(nextInterval(now), drain)
end

--- Queues a message for a player, or for a group channel when `channel` is given (`target` is then nil). Returns
-- false when the message can't be sent at all. `onDequeued`, when given, runs once the message leaves the queue: sent,
-- or dropped because the queue was full.
function ns.Send(message, target, onDequeued, channel)
    local to = tostring(target or channel)
    if #message > ns.MAX_MESSAGE_BYTES then
        ns.Log.Error("comm", "message too long (%d bytes) for %s; %s not sent", #message, to, message:sub(1, 2))
        return false
    end
    if #queue >= MAX_QUEUE then
        ns.Log.Warn("comm", "send queue full; dropping the oldest message")
        local dropped = table.remove(queue, 1)
        if dropped.onDequeued then dropped.onDequeued() end
    end
    queue[#queue + 1] = { message = message, target = target, channel = channel, to = to, onDequeued = onDequeued }
    if ns.IsBusy() or ns.MessagingLocked() then ns.Log.Debug("comm", "queued %s for %s until combat or the lockdown ends", message:sub(1, 2), to) end
    if not draining then
        draining = true
        drain()
    end
    return true
end

--- Resumes sending after combat, an encounter or the addon-message lockdown.
function ns.ResumeSending()
    if not draining and #queue > 0 then
        draining = true
        drain()
    end
end

function ns.QueuedMessages() return #queue end

-- ─── "No player named ... is currently playing." ─────────────────────────────

-- The client's notice for a whisper to someone offline, as a pattern that captures the name.
local function offlinePattern()
    local notice = type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and ERR_CHAT_PLAYER_NOT_FOUND_S
        or "No player named '%s' is currently playing."
    local escaped = notice:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
    return "^" .. escaped:gsub("%%s", "(.+)") .. "$"
end

--- Chat filter for CHAT_MSG_SYSTEM: an endorsement whispers its target twice (the request, then the record), so the
-- client says "No player named ... is currently playing." twice for someone who logged off. The first notice shows;
-- the same notice for a name we whispered is hidden for OFFLINE_WINDOW seconds after it. Returns true to hide.
-- `lineId` (the event's 11th argument) tells one notice shown in several chat frames from a second notice.
function ns.FilterOfflineNotice(_, _, text, ...)
    -- A notice the client hides from addons (Midnight's secret values) is left alone.
    local name = type(text) == "string" and not (issecretvalue and issecretvalue(text)) and text:match(offlinePattern())
    local now = clock()
    if not name or now - (whispered[name:lower()] or -math.huge) > OFFLINE_WINDOW then return false end
    local key, line = name:lower(), select(10, ...) or now
    local shown = offline[key]
    if not shown or now - shown.at > OFFLINE_WINDOW then
        offline[key] = { at = now, line = line }
        return false
    end
    return line ~= shown.line
end

if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", ns.Log.Wrap("comm", ns.FilterOfflineNotice))
end

-- Handlers for each message kind ("Q:", "A:", "R:"), registered by Endorse.lua.
ns.messageHandlers = {}

--- Dispatches one received message. `sender` is the client's sender string, `channel` the channel it arrived on
-- (CHAT_MSG_ADDON's third argument). The handshake ("Q:", "A:") is only ever taken from a whisper; a finished record
-- ("R:") also from a group channel, where its handler decides whether it's ours or one to carry.
function ns.OnAddonMessage(message, sender, channel)
    if type(message) ~= "string" or #message < 3 or message:sub(2, 2) ~= ":" then
        ns.Log.Warn("comm", "ignored a malformed message from %s", tostring(sender))
        return
    end
    local kind = message:sub(1, 1)
    if channel ~= "WHISPER" and not (kind == "R" and GROUP_CHANNELS[channel]) then
        ns.Log.Warn("comm", "ignored %s: on %s from %s (whispers only, or the group channel for a record)", kind,
            tostring(channel), tostring(sender))
        return
    end
    local handler = ns.messageHandlers[kind]
    if not handler then
        ns.Log.Warn("comm", "ignored unknown message kind %q from %s", kind, tostring(sender))
        return
    end
    ns.Log.Debug("comm", "received %s from %s on %s (%d bytes)", message:sub(1, 2), tostring(sender), channel, #message)
    handler(message:sub(3), sender, channel)
end
