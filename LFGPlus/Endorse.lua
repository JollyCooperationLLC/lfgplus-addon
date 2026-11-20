-- Endorsing: the two-phase handshake.
--
--   endorser                         endorsee
--   Q: request  ───────────────────▶ checks it names them, applies their ack setting, signs with the ack key
--               ◀─────────────────── A: counter ‖ acknowledgment
--   adds the tag, signs with the real or drop key, stores the record
--   R: record   ───────────────────▶ stores its copy, shows "X endorsed you"
--   R: record   ── group channel ───▶ everyone else there carries a copy for their own upload
--
-- No ack within ACK_TIMEOUT of the request going out (no addon, ignored, offline) gives an unproven record, which
-- still counts. An ack that comes later, within a day, proves it after all: the same request is signed again with the
-- ack, replaces the unproven record (same counter) and is sent again, and whoever holds the unproven copy swaps it
-- for the proven one. A quiet endorsement is signed with the drop key; nothing on screen, in the log or on the wire
-- tells it apart, and it goes to the group channel exactly as a real one does.
-- Each player can be endorsed once, ever: ns.db.endorsed remembers who, real and quiet alike. One their addon
-- never confirmed (unproven) can be replaced by a confirmed one, which the site then counts in its place.

local _, ns = ...

local ACK_TIMEOUT = 15
local LATE_ACK_KEEP = 86400         -- seconds a timed-out endorsement still takes a late ack
local CLOCK_SKEW = 300              -- seconds an incoming request's time may differ from ours
local COUNTER_EPOCH = 1767225600    -- 2026-01-01: counters start from seconds since then
local DAILY_CAP = 20                -- real endorsements per UTC day; quiet ones don't count
local RECORD_KEEP_DAYS = 35         -- the site refuses records older than 30 days
local UPLOAD_MAX_AGE = 30 * 86400 - 3600 -- older records aren't offered for upload: the site's 30 days, less an hour
local RECORD_TAIL_BYTES = 28        -- a record is its request and then 28 bytes: ack 15, tags 1, record MAC 12
local MAX_REQUESTS_PER_MINUTE = 6   -- per sender, so nobody can flood someone with popups
local MAX_HEARD_PER_MINUTE = 20     -- records carried per sender: a day's real endorsements, given after one raid
local MAX_CARRIED = 200             -- copies of other players' records kept for upload; the oldest go first
local MAX_UPLOAD_LINES = 500        -- records the site takes in one paste (api-types MAX_RECORDS_PER_UPLOAD)

ns.ENDORSE_CONSTANTS = { ACK_TIMEOUT = ACK_TIMEOUT, DAILY_CAP = DAILY_CAP }

local pending = {}        -- outgoing, by counter
local requestLog = {}     -- incoming request times, by sender key
local heardLog = {}       -- times a record heard on the group channel was up for carrying, by sender key

local function utcDay(t)
    return date and date("!%Y-%m-%d", t) or tostring(math.floor(t / 86400))
end

local function after(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, ns.Log.Wrap("timer:endorse", fn)) end
end

--- What a trial account sees instead of an endorsement: it can't send addon messages, so it can't endorse.
ns.TRIAL_TEXT = "Trial accounts can't send the messages endorsing needs. You'll still see who other players endorsed."

--- True on a Trial or Veteran (lapsed) account, which can't send addon messages (on WoW Forever
-- too). The client says so; a client without either function is neither.
function ns.IsTrialAccount()
    if IsTrialAccount and IsTrialAccount() then return true end
    if IsVeteranTrialAccount and IsVeteranTrialAccount() then return true end
    return false
end

--- Our own identity, cached per session (UnitName("player") doesn't change while logged in). Specs set ns.player.
function ns.PlayerIdentity()
    if not ns.player then ns.player = ns.UnitIdentity("player") end
    return ns.player
end

--- Where the player is: (1, instance id) inside an instance, (2, uiMapID) outside, (0, 0) when unknown.
function ns.CurrentLocation()
    if IsInInstance and IsInInstance() and GetInstanceInfo then
        local instanceId = select(8, GetInstanceInfo())
        if type(instanceId) == "number" and instanceId > 0 then return 1, instanceId end
    end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if type(map) == "number" and map > 0 then return 2, map end
    return 0, 0
end

--- The next record counter: strictly increasing, and seeded from the clock so two installs of the same account
-- (separate SavedVariables) don't reuse counters.
function ns.NextCounter(now)
    local counter = math.max((tonumber(ns.db.lastCounter) or 0) + 1, now - COUNTER_EPOCH)
    ns.db.lastCounter = counter
    return counter
end

--- Real endorsements left today (UTC). Only for the cap: never shown, so nobody watching can tell quiet from real.
function ns.RealEndorsementsLeft(now)
    local daily = ns.db.dailyCounter
    if daily.day ~= utcDay(now) then return DAILY_CAP end
    return math.max(0, DAILY_CAP - (daily.used or 0))
end

local function useDaily(now)
    local daily = ns.db.dailyCounter
    local today = utcDay(now)
    if daily.day ~= today then daily.day, daily.used = today, 0 end
    daily.used = (daily.used or 0) + 1
end

local function characterFor(identity)
    return { name = identity.name, realm = identity.realm or "", guid = identity.guid }
end

--- Redraws the LFG+ window, when it's loaded, after the records changed.
local function refresh()
    if ns.RefreshWindow then ns.RefreshWindow() end
end

--- The next storage number, for a record or carried copy stored or replaced now ("I uploaded these" marks up to one).
local function nextSeq()
    ns.db.lastSeq = (tonumber(ns.db.lastSeq) or 0) + 1
    return ns.db.lastSeq
end

--- True when an upload line holds the same request as a decoded record: the same endorsement, maybe another ack.
local function sameRequest(text, rec)
    local held = ns.DecodeRecord(ns.RecordFromText(text))
    return held ~= nil and held.requestBytes == rec.requestBytes
end

--- Stores a record we gave or received, once (by endorser account and counter): "stored". A proven copy of an
-- endorsement we hold unproven replaces it: "upgraded". Anything else: nil.
local function storeRecord(direction, text, rec, otherName)
    local proven = rec.ackKeyVersion > 0
    for _, existing in ipairs(ns.db.records) do
        if existing.account == rec.endorserAccount and existing.counter == rec.counter then
            if not (proven and not existing.proven and sameRequest(existing.text, rec)) then return nil end
            existing.text, existing.proven, existing.seq = text, true, nextSeq()
            refresh()
            return "upgraded"
        end
    end
    table.insert(ns.db.records, {
        dir = direction, text = text, at = rec.endorsedAt, counter = rec.counter, account = rec.endorserAccount,
        name = otherName, tags = rec.tags, proven = proven, seq = nextSeq(),
    })
    refresh()
    return "stored"
end

local function prune(list, now)
    local keep = {}
    for _, r in ipairs(list) do
        if (now - (r.at or 0)) <= RECORD_KEEP_DAYS * 86400 then keep[#keep + 1] = r end
    end
    return keep, #list - #keep
end

--- Forgets timed-out endorsements too old for a late ack.
local function pruneLateAcks(now)
    for counter, late in pairs(ns.db.lateAcks) do
        if now - (late.at or 0) > LATE_ACK_KEEP then ns.db.lateAcks[counter] = nil end
    end
end

--- Drops records, our own and carried, older than the site accepts, and endorsements too old for a late ack.
function ns.PruneRecords(now)
    local dropped, droppedCarried
    ns.db.records, dropped = prune(ns.db.records, now)
    ns.db.carried, droppedCarried = prune(ns.db.carried, now)
    if dropped + droppedCarried > 0 then
        ns.Log.Info("endorse", "pruned %d records and %d carried copies older than %d days", dropped, droppedCarried, RECORD_KEEP_DAYS)
    end
    pruneLateAcks(now)
end

-- ─── Endorser ────────────────────────────────────────────────────────────────

--- Signs an endorsement's request with an ack: with the drop key when quiet, else the real key.
local function sign(p, ack)
    local bytes = ns.EncodeRecord(p.requestBytes, ack, p.tags, p.quiet and ns.keys.drop or ns.keys.real)
    return bytes, ns.DecodeRecord(bytes)
end

--- Sends a finished record to its endorsee, and to our group when we're in one.
local function deliver(bytes, target)
    local message = "R:" .. ns.ToBase64Url(bytes)
    ns.Send(message, ns.WhisperTarget(target))
    -- The group hears it too, so anyone there who uploads delivers it. Real and quiet alike: nothing here
    -- reads p.quiet, so the two can't be told apart by whether or how they were sent.
    local channel = ns.GroupChannel()
    if channel then ns.Send(message, nil, nil, channel) end
end

local function finish(counter, ack)
    local p = pending[counter]
    if not p then return end
    pending[counter] = nil
    local bytes, rec = sign(p, ack)
    storeRecord("given", ns.RecordToText(bytes), rec, p.target.name)
    local proven = ack.ackKeyVersion > 0
    -- A second unconfirmed endorsement changes nothing on the site, so the first stays the one this install shows.
    if proven or not ns.AlreadyEndorsed(p.target) then
        ns.db.endorsed[p.target.key] = { at = rec.endorsedAt, tags = p.tags, proven = proven }
    end
    if not proven then
        -- Kept a day, so an ack that comes after all ("ask first" accepted late, a slow whisper) still proves it.
        pruneLateAcks(ns.Now())
        ns.db.lateAcks[counter] = {
            request = ns.ToBase64Url(p.requestBytes), tags = p.tags, quiet = p.quiet, endorsedAt = rec.endorsedAt,
            target = { name = p.target.name, realm = p.target.realm, guid = p.target.guid, key = p.target.key }, at = ns.Now(),
        }
    end
    deliver(bytes, p.target)
    -- A thank-you in chat, which players without LFG+ see too. Sent for real and quiet alike, and only here, not when a
    -- late ack proves the endorsement: once per endorsement.
    if ns.db.thankWhisper then ns.SendChat(ns.ThanksText(p.tags), ns.WhisperTarget(p.target)) end
    ns.Log.Info("endorse", "record %d for %s finished: %s, tags %d", counter, p.target.name,
        proven and "proven" or "unproven", p.tags)
    -- Identical for real and quiet, on purpose.
    ns.Print(("You endorsed %s \194\183 %s."):format(p.target.name, ns.TagText(p.tags)))
    if ns.OnEndorsementFinished then ns.OnEndorsementFinished(p.target, p.tags) end
end

--- A late ack for an endorsement that timed out: the same request, signed again with the ack, takes the unproven
-- record's place (same counter) and goes out again like the first. Nothing is printed and no daily slot is used.
local function proveLate(counter, late, ack)
    if ack.ackKeyVersion == 0 then return end -- still unproven: nothing to replace
    if not ns.IsLinked() or late.request.endorserAccount ~= ns.account.accountId
        or late.request.keyVersion ~= ns.account.keyVersion then
        ns.Log.Warn("endorse", "late ack %d from %s: linked to another setup code since; not proven", counter, late.target.name)
        return
    end
    ns.db.lateAcks[counter] = nil
    local bytes, rec = sign(late, ack)
    storeRecord("given", ns.RecordToText(bytes), rec, late.target.name)
    ns.db.endorsed[late.target.key] = { at = rec.endorsedAt, tags = late.tags, proven = true }
    deliver(bytes, late.target)
    ns.Log.Info("endorse", "late ack %d from %s: record proven and sent again", counter, late.target.name)
end

--- Whether this install has endorsed the character before, confirmed or not.
function ns.AlreadyEndorsed(identity)
    return identity ~= nil and ns.db.endorsed[identity.key] ~= nil
end

--- Whether this install's endorsement of the character is final: their addon confirmed it. One it never
-- confirmed can still be replaced by a confirmed one.
function ns.EndorsementFinal(identity)
    local mine = ns.db.endorsed[identity.key]
    return mine ~= nil and mine.proven == true
end

--- The members not endorsed yet, in order: the ones a prompt still offers. An unconfirmed endorsement keeps its player
-- out of the prompt too, so nobody is asked again after every run; the menu and /endorse can still replace it.
function ns.NotYetEndorsed(members)
    local left = {}
    for _, m in ipairs(members) do
        if not ns.AlreadyEndorsed(m) then left[#left + 1] = m end
    end
    return left
end

--- Starts endorsing a character. `target` is an identity (ns.UnitIdentity); `tags` exactly one tag bit (Record.lua),
-- since there is no untagged endorsement; `quiet` signs with the drop key. Returns true, or false and a
-- message for the player.
function ns.Endorse(target, tags, quiet)
    tags = tonumber(tags)
    if not ns.IsLinked() then return false, "Link your LFG+ account first: type /lfgplus setup." end
    if ns.IsTrialAccount() then return false, ns.TRIAL_TEXT end
    local region = ns.RegionId()
    if not region then return false, "LFG+ doesn't support this region yet." end
    local me = ns.PlayerIdentity()
    if not me then return false, "LFG+ couldn't read your own character. Try again in a moment." end
    if not target or not target.name then return false, "Target another player to endorse them." end
    if ns.SameCharacter(me, target) then return false, "You can't endorse yourself." end
    if ns.EndorsementFinal(target) then return false, ("You've already endorsed %s."):format(target.name) end
    if not ns.IsSingleTag(tags) then return false, "Pick what they did best: /endorse fun, skilled, helpful or leader." end
    local now = ns.Now()
    if not quiet and ns.RealEndorsementsLeft(now) <= 0 then
        return false, ("You've used today's %d endorsements. More tomorrow."):format(DAILY_CAP)
    end
    for _, p in pairs(pending) do
        if ns.SameCharacter(p.target, target) then return false, ("Already endorsing %s."):format(target.name) end
    end

    local kind, id = ns.CurrentLocation()
    local request = {
        gameVersion = ns.gameVersion, region = region, keyVersion = ns.account.keyVersion,
        endorserAccount = ns.account.accountId, counter = ns.NextCounter(now), endorsedAt = now,
        locationKind = kind, locationId = id, endorser = characterFor(me), endorsee = characterFor(target),
    }
    local requestBytes, err = ns.EncodeRequest(request)
    if not requestBytes then
        ns.Log.Error("endorse", "couldn't encode a request for %s: %s", target.name, tostring(err))
        return false, "LFG+ couldn't endorse that character."
    end
    -- The request and the record must each fit one addon message ("Q:" or "R:" and base64url); the record is the
    -- longer. Checked before anything is used up or waits for an ack, so nothing is left half-done.
    local longest = 2 + math.ceil((#requestBytes + RECORD_TAIL_BYTES) * 4 / 3)
    if longest > ns.MAX_MESSAGE_BYTES then
        ns.Log.Warn("endorse", "endorsing %s needs a %d-byte message; the limit is %d", target.name, longest, ns.MAX_MESSAGE_BYTES)
        return false, ("LFG+ can't endorse %s: your names are too long to fit in one message."):format(target.name)
    end
    if not quiet then useDaily(now) end
    pending[request.counter] = { request = request, requestBytes = requestBytes, tags = tags, quiet = quiet and true or false, target = target, started = now }
    ns.Log.Info("endorse", "request %d to %s (guid %s) at %d:%d, tags %d", request.counter, target.name,
        tostring(target.guid), kind, id, tags)
    -- The ack window opens when the request leaves the queue, not now: a request held through combat would otherwise
    -- time out before the endorsee ever saw it.
    local counter = request.counter
    ns.Send("Q:" .. ns.ToBase64Url(requestBytes), ns.WhisperTarget(target), function()
        after(ACK_TIMEOUT, function()
            if pending[counter] then
                ns.Log.Info("endorse", "no ack from %s within %ds: unproven", target.name, ACK_TIMEOUT)
                finish(counter, ns.UNPROVEN_ACK)
            end
        end)
    end)
    return true
end

--- For specs and the timeout: finishes a pending endorsement without an ack.
function ns.TimeoutEndorsement(counter) finish(counter, ns.UNPROVEN_ACK) end
function ns.PendingEndorsements() return pending end

--- The endorsement an ack answers: one waiting for it, or one that timed out within the last day (marked `late`).
local function answered(counter, now)
    if pending[counter] then return pending[counter] end
    local late = ns.db.lateAcks[counter]
    if not late or now - (late.at or 0) > LATE_ACK_KEEP then return nil end
    local requestBytes = ns.FromBase64Url(late.request)
    local request = ns.DecodeRequest(requestBytes)
    if not request then return nil end -- the saved copy was edited or damaged
    return { request = request, requestBytes = requestBytes, tags = late.tags, quiet = late.quiet, target = late.target, late = true }
end

ns.messageHandlers.A = function(payload, sender)
    local bytes = ns.FromBase64Url(payload)
    if not bytes or #bytes ~= 19 then
        ns.Log.Warn("endorse", "ignored a malformed ack from %s", tostring(sender))
        return
    end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    local counter = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    local p = answered(counter, ns.Now())
    local from = ns.IdentityFromSender(sender)
    if not p then
        ns.Log.Warn("endorse", "ack %d from %s matches no pending endorsement", counter, tostring(sender))
        return
    end
    if not ns.SameCharacter(from, p.target) then
        ns.Log.Warn("endorse", "ack %d came from %s, not %s; ignored", counter, tostring(sender), p.target.name)
        return
    end
    local ackBytes = bytes:sub(5)
    local k1, k2, kind, i1, i2, i3, i4 = ackBytes:byte(1, 7)
    local ack = {
        ackKeyVersion = k1 * 256 + k2, ackLocationKind = kind,
        ackLocationId = ((i1 * 256 + i2) * 256 + i3) * 256 + i4, ackMac = ackBytes:sub(8, 15),
    }
    if ack.ackKeyVersion == 0 then
        ns.Log.Warn("endorse", "ack %d from %s has key version 0; treating as unproven", counter, p.target.name)
        ack = ns.UNPROVEN_ACK
    elseif ack.ackLocationKind ~= p.request.locationKind or ack.ackLocationId ~= p.request.locationId then
        ns.Log.Info("endorse", "ack %d: %s saw %d:%d, we saw %d:%d", counter, p.target.name, ack.ackLocationKind,
            ack.ackLocationId, p.request.locationKind, p.request.locationId)
    end
    if p.late then return proveLate(counter, p, ack) end
    finish(counter, ack)
end

-- ─── Endorsee ────────────────────────────────────────────────────────────────

--- Which ack setting applies to a sender: "group", "guild", "friends" or "others".
function ns.RelationOf(identity)
    local target = ns.WhisperTarget(identity)
    if (UnitInParty and UnitInParty(target)) or (UnitInRaid and UnitInRaid(target)) then return "group" end
    if identity.guid and IsGuildMember and IsGuildMember(identity.guid) then return "guild" end
    if C_GuildInfo and C_GuildInfo.MemberExistsByName and C_GuildInfo.MemberExistsByName(target) then return "guild" end
    if identity.guid and C_FriendList and C_FriendList.IsFriend and C_FriendList.IsFriend(identity.guid) then return "friends" end
    if identity.guid and C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID and C_BattleNet.GetGameAccountInfoByGUID(identity.guid) then
        return "friends"
    end
    return "others"
end

--- Notes one more event for `key` in `log`, and says whether that makes more than `limit` within a minute.
local function rateLimited(log, key, now, limit)
    local times = log[key] or {}
    local recent = {}
    for _, t in ipairs(times) do if now - t < 60 then recent[#recent + 1] = t end end
    recent[#recent + 1] = now
    log[key] = recent
    return #recent > limit
end

--- Signs and sends the acknowledgment for a checked request.
function ns.SendAck(request, requestBytes, sender)
    if not ns.IsLinked() then return end
    local kind, id = ns.CurrentLocation()
    local mac = ns.AckMac(ns.keys.ack, requestBytes, kind, id)
    local ack = ns.EncodeAck({ ackKeyVersion = ns.account.keyVersion, ackLocationKind = kind, ackLocationId = id, ackMac = mac })
    local counter = string.char(math.floor(request.counter / 16777216) % 256, math.floor(request.counter / 65536) % 256,
        math.floor(request.counter / 256) % 256, request.counter % 256)
    ns.Send("A:" .. ns.ToBase64Url(counter .. ack), sender)
    ns.Log.Info("endorse", "acked request %d from %s at %d:%d", request.counter, request.endorser.name, kind, id)
end

--- Checks an incoming request. Returns the request, or nil and the reason (logged, never shown).
function ns.CheckRequest(bytes, sender, now)
    local req = ns.DecodeRequest(bytes)
    if not req then return nil, "malformed" end
    if req.gameVersion ~= ns.gameVersion then return nil, "another game version" end
    if req.region ~= ns.RegionId() then return nil, "another region" end
    if math.abs(req.endorsedAt - now) > CLOCK_SKEW then return nil, "time too far from ours" end
    local me = ns.PlayerIdentity()
    if not me then return nil, "own identity unknown" end
    local named = { name = req.endorsee.name, realm = req.endorsee.realm, key = ns.CharacterKey(req.endorsee.name, req.endorsee.realm) }
    if not ns.SameCharacter(named, me) then return nil, "names " .. req.endorsee.name .. ", not us" end
    if me.guid and req.endorsee.guid and me.guid ~= req.endorsee.guid then return nil, "GUID isn't ours" end
    local from = ns.IdentityFromSender(sender)
    local endorser = { key = ns.CharacterKey(req.endorser.name, req.endorser.realm) }
    if not ns.SameCharacter(from, endorser) then return nil, "sent by someone other than the endorser" end
    return req
end

ns.messageHandlers.Q = function(payload, sender)
    local now = ns.Now()
    local from = ns.IdentityFromSender(sender)
    if from and rateLimited(requestLog, from.key, now, MAX_REQUESTS_PER_MINUTE) then
        ns.Log.Warn("endorse", "too many requests from %s; ignored", tostring(sender))
        return
    end
    local bytes = ns.FromBase64Url(payload)
    local req, why = ns.CheckRequest(bytes, sender, now)
    if not req then
        ns.Log.Warn("endorse", "ignored a request from %s: %s", tostring(sender), tostring(why))
        return
    end
    if not ns.IsLinked() then
        ns.Log.Info("endorse", "request %d from %s not acked: account not linked", req.counter, req.endorser.name)
        return
    end
    from.guid = req.endorser.guid
    local relation = ns.RelationOf(from)
    local mode = ns.AckModeFor(relation)
    ns.Log.Info("endorse", "request %d from %s (%s): %s", req.counter, req.endorser.name, relation, mode)
    if mode == "ask" and ns.AskToAck then
        ns.AskToAck(req, bytes, sender)
    else
        ns.SendAck(req, bytes, sender)
    end
end

--- Keeps a copy of a record between two other players, heard on the group channel, so our upload delivers it too.
-- Only the site can check a signature, so this keeps out what it can: a record older than we'd keep or dated
-- ahead of our clock, a flood from one sender, and anything we already hold. A proven copy of a request we carry
-- unproven (a late ack) takes its place; any other record with the same counter is carried beside it, so a forged
-- one can't push out the real one. Real and quiet records look the same here and are carried the same.
local function carry(bytes, rec, from, now)
    if rec.endorsedAt < now - RECORD_KEEP_DAYS * 86400 or rec.endorsedAt > now + CLOCK_SKEW then
        ns.Log.Warn("endorse", "not carrying record %d from %s: its time is outside the upload window", rec.counter, from.name)
        return
    end
    if rateLimited(heardLog, from.key, now, MAX_HEARD_PER_MINUTE) then
        ns.Log.Warn("endorse", "too many records from %s; not carrying this one", from.name)
        return
    end
    for _, own in ipairs(ns.db.records) do
        if own.account == rec.endorserAccount and own.counter == rec.counter then return end
    end
    local text, proven = ns.RecordToText(bytes), rec.ackKeyVersion > 0
    for _, held in ipairs(ns.db.carried) do
        if held.text == text then return end
        if proven and not held.proven and held.account == rec.endorserAccount and held.counter == rec.counter
            and sameRequest(held.text, rec) then
            held.text, held.proven, held.seq = text, true, nextSeq()
            ns.Log.Info("endorse", "carrying the proven copy of record %d from %s instead", rec.counter, from.name)
            refresh()
            return
        end
    end
    table.insert(ns.db.carried, { text = text, at = rec.endorsedAt, account = rec.endorserAccount, counter = rec.counter,
        proven = proven, seq = nextSeq() })
    while #ns.db.carried > MAX_CARRIED do table.remove(ns.db.carried, 1) end
    ns.Log.Info("endorse", "carrying record %d from %s for %s (%d carried)", rec.counter, from.name, rec.endorsee.name, #ns.db.carried)
    refresh()
end

ns.messageHandlers.R = function(payload, sender, channel)
    local bytes = ns.FromBase64Url(payload)
    local rec = ns.DecodeRecord(bytes)
    if not rec then
        ns.Log.Warn("endorse", "ignored a malformed record from %s", tostring(sender))
        return
    end
    local me = ns.PlayerIdentity()
    local endorser = { key = ns.CharacterKey(rec.endorser.name, rec.endorser.realm) }
    local named = { key = ns.CharacterKey(rec.endorsee.name, rec.endorsee.realm) }
    local heard = channel ~= "WHISPER" -- on a group channel (Comm.lua lets nothing else through)
    if heard and ns.SameCharacter(endorser, me) then return end -- our own record: the group channel echoes it back
    local forMe = ns.SameCharacter(named, me)
    local from = ns.IdentityFromSender(sender)
    -- A whispered record must name us. One heard in the group may name anyone; either way its endorser sent it.
    if not (forMe or heard) or not ns.SameCharacter(from, endorser) then
        ns.Log.Warn("endorse", "ignored record %d from %s: wrong endorsee or sender", rec.counter, tostring(sender))
        return
    end
    if not forMe then return carry(bytes, rec, from, ns.Now()) end
    -- Ours, whispered or heard: stored once, so the two copies give one record and one toast. A proven copy of one we
    -- hold unproven (their late ack) replaces it, without another toast.
    local stored = storeRecord("received", ns.RecordToText(bytes), rec, rec.endorser.name)
    if stored == "stored" then
        ns.Log.Info("endorse", "received record %d from %s, tags %d, %s", rec.counter, rec.endorser.name, rec.tags,
            rec.ackKeyVersion > 0 and "proven" or "unproven")
        if ns.ShowEndorsedToast then ns.ShowEndorsedToast(rec) end
    elseif stored == "upgraded" then
        ns.Log.Info("endorse", "received the proven copy of record %d from %s", rec.counter, rec.endorser.name)
    end
end

--- How many records we hold that we gave, that we received, and that we carry for others in our groups.
function ns.RecordCounts()
    local given, received = 0, 0
    for _, r in ipairs(ns.db.records) do
        if r.dir == "given" then given = given + 1 else received = received + 1 end
    end
    return given, received, #ns.db.carried
end

--- True for a record or carried copy the site still takes at `now`: not older than 30 days (less a margin).
local function uploadable(r, now)
    return now - (r.at or 0) <= UPLOAD_MAX_AGE
end

--- True for a copy the site still takes that isn't marked uploaded yet ("I uploaded these").
local function waiting(r, now)
    return uploadable(r, now) and (ns.db.uploadedSeq == nil or (r.seq or 0) > ns.db.uploadedSeq)
end

--- True for a record that still waits for upload at `now`: the Endorsements tab lists only these.
function ns.IsWaiting(r, now)
    return waiting(r, now)
end

--- What waits for upload at `now`: records we gave, records we received, copies we carry. Records the site would
-- refuse as too old, and those marked uploaded, don't count.
function ns.WaitingCounts(now)
    local given, received, carried = 0, 0, 0
    for _, r in ipairs(ns.db.records) do
        if waiting(r, now) then
            if r.dir == "given" then given = given + 1 else received = received + 1 end
        end
    end
    for _, c in ipairs(ns.db.carried) do
        if waiting(c, now) then carried = carried + 1 end
    end
    return given, received, carried
end

--- What waits for upload, in one line for the window and the minimap button; nil when nothing does.
function ns.WaitingLine()
    local given, received, carried = ns.WaitingCounts(ns.Now())
    if given + received + carried == 0 then return nil end
    local line = ("Waiting to upload: %d given, %d received"):format(given, received)
    if carried > 0 then line = line .. (", %d from your groups"):format(carried) end
    return line .. "."
end

--- "I uploaded these": every record and carried copy stored up to `seq` (ns.db.lastSeq when the upload box was
-- filled) no longer counts as waiting, and leaves the upload box.
function ns.MarkUploaded(seq)
    ns.db.uploadedSeq = math.max(tonumber(seq) or 0, ns.db.uploadedSeq or 0)
    ns.Log.Info("endorse", "marked everything up to %d as uploaded", ns.db.uploadedSeq)
    refresh()
end

--- Upload lines: what still waits for upload, our own records then the carried copies. Those marked uploaded ("I
-- uploaded these") and those the site would refuse as too old are left out.
function ns.UploadLines()
    local lines, now = {}, ns.Now()
    for _, r in ipairs(ns.db.records) do
        if waiting(r, now) then lines[#lines + 1] = r.text end
    end
    for _, c in ipairs(ns.db.carried) do
        if waiting(c, now) then lines[#lines + 1] = c.text end
    end
    return lines
end

--- The upload lines cut into pastes the site takes whole (MAX_UPLOAD_LINES each), in order. Empty when there's nothing.
function ns.UploadParts()
    local parts, lines = {}, ns.UploadLines()
    for i, line in ipairs(lines) do
        local part = math.floor((i - 1) / MAX_UPLOAD_LINES) + 1
        parts[part] = parts[part] or {}
        table.insert(parts[part], line)
    end
    return parts
end
