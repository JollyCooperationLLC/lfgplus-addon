-- Two addon instances endorsing each other over a fake network. Each client
-- is linked with a setup code from test/test-vectors/setup-code.json, so the keys are the vector keys and the records
-- can be checked cryptographically: the ack MAC by the endorsee's ack key, the record MAC by the real or drop key.
_G.bit = _G.bit or require("bit")
local loader = require("test.helpers.load_addon")

local codes = loader.read_vectors("setup-code.json")
local FILES = { "Core.lua", "Log.lua", "Crypto.lua", "SetupCode.lua", "Settings.lua", "Identity.lua", "Record.lua",
    "Comm.lua", "Endorse.lua", "Format.lua" }

describe("the endorsement handshake", function()
    local clock, timers, net, wire, clients, combat, party, group

    local function advance(seconds)
        local target = clock + seconds
        while true do
            table.sort(timers, function(a, b) return a.due < b.due end)
            local t = timers[1]
            if not t or t.due > target then break end
            table.remove(timers, 1)
            clock = math.max(clock, t.due)
            t.fn()
        end
        clock = target
    end

    local function client(name, guid, code)
        local ns = loader.load(FILES)
        ns.db = ns.ApplyDefaults({}, ns.DEFAULTS)
        ns.gameVersion = 40 -- WoW Forever: realmless
        ns.player = { name = name, realm = "", guid = guid, key = ns.CharacterKey(name, "") }
        ns.chat = {}
        ns.Print = function(text) table.insert(ns.chat, text) end
        ns.SendRaw = function(message, target, channel)
            table.insert(net, { from = ns, to = target, channel = channel, message = message })
            -- Everything that ever went out, by shape: what an onlooker could tell about a message without its bytes.
            table.insert(wire, { from = name, to = target, channel = channel or "WHISPER", kind = message:sub(1, 2), bytes = #message })
            return true
        end
        if code then assert(ns.LinkAccount(code)) end
        clients[name] = ns
        return ns
    end

    --- Delivers queued messages and runs timers, half a second at a time. A whisper reaches its target; a message on
    -- a group channel reaches everyone in the party, its sender included (the client echoes it back).
    local function pump(seconds)
        for _ = 1, (seconds or 3) * 2 do
            local batch = net
            net = {}
            for _, m in ipairs(batch) do
                if m.channel then
                    for name, to in pairs(clients) do
                        if party[name] then to.OnAddonMessage(m.message, m.from.player.name, m.channel) end
                    end
                else
                    local to = clients[m.to]
                    if to then to.OnAddonMessage(m.message, m.from.player.name, "WHISPER") end
                end
            end
            advance(0.5)
        end
    end

    --- Counts the "X endorsed you" toasts a client would show (UI.lua isn't loaded here), in ns.toasts.
    local function watchToasts(ns)
        ns.toasts = {}
        ns.ShowEndorsedToast = function(rec) table.insert(ns.toasts, rec) end
    end

    local function recordOf(ns, i)
        return ns.DecodeRecord(ns.RecordFromText(ns.db.records[i or 1].text))
    end

    local function logged(ns, text)
        for _, line in ipairs(ns.Log.Recent(2000)) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    --- The 4-byte counter prefix of an ack message.
    local function counterBytes(counter)
        return string.char(math.floor(counter / 16777216) % 256, math.floor(counter / 65536) % 256,
            math.floor(counter / 256) % 256, counter % 256)
    end

    local function signedWith(ns, rec, key)
        local ack = { ackKeyVersion = rec.ackKeyVersion, ackLocationKind = rec.ackLocationKind, ackLocationId = rec.ackLocationId, ackMac = rec.ackMac }
        return ns.EncodeRecord(rec.requestBytes, ack, rec.tags, key):sub(-12) == rec.recordMac
    end

    before_each(function()
        clock, timers, net, wire, clients, combat, party, group = 1794096000, {}, {}, {}, {}, false, {}, nil
        _G.CreateFrame = nil
        _G.LFGPlusLog = nil
        _G.date = os.date
        _G.GetServerTime = function() return clock end
        _G.C_Timer = { After = function(s, fn) table.insert(timers, { due = clock + s, fn = fn }) end }
        _G.InCombatLockdown = function() return combat end
        _G.UnitAffectingCombat = function() return combat end
        _G.GetCurrentRegion = function() return 1 end
        _G.IsInInstance = function() return true, "party" end
        _G.GetInstanceInfo = function() return "Blackrock Depths", "party", 1, "Normal", 5, 0, false, 230 end
        _G.UnitInParty = function(name) return party[name] or false end
        -- `group` is the channel that reaches the group, as a client would have it: nil when not grouped.
        _G.LE_PARTY_CATEGORY_INSTANCE = 2
        _G.IsInGroup = function(category)
            if category == LE_PARTY_CATEGORY_INSTANCE then return group == "INSTANCE_CHAT" end
            return group ~= nil
        end
        _G.IsInRaid = function() return group == "RAID" end
    end)

    --- Corvina and Middle Foot, linked and in a party together.
    local function pair()
        local a = client("Corvina Ashby", "Player-4395-0A1B2C3D", codes.valid[1].input)
        local b = client("Middle Foot", "Player-4395-00000007", codes.valid[2].input)
        party["Corvina Ashby"], party["Middle Foot"] = true, true
        group = "PARTY"
        return a, b
    end

    --- A third player in the same party.
    local function third()
        local c = client("Sir Rocky", "Player-4395-00000099", codes.valid[3].input)
        party["Sir Rocky"] = true
        return c
    end

    --- An "R:" message for a record nobody signed: the addon can't check a signature, so it takes these like any other.
    local function heardRecord(ns, changes)
        local r = {
            gameVersion = 40, region = 1, keyVersion = 1, endorserAccount = string.rep("0", 31) .. "9", counter = 7,
            endorsedAt = clock, locationKind = 1, locationId = 230,
            endorser = { name = "Corvina Ashby", realm = "", guid = "Player-4395-0A1B2C3D" },
            endorsee = { name = "Middle Foot", realm = "", guid = "Player-4395-00000007" },
        }
        for k, v in pairs(changes or {}) do r[k] = v end
        local bytes = assert(ns.EncodeRequest(r)) .. ns.EncodeAck(ns.UNPROVEN_ACK) .. "\1" .. string.rep("x", 12)
        return "R:" .. ns.ToBase64Url(bytes), ns.RecordToText(bytes)
    end

    it("produces a proven record both players hold, signed with the real key", function()
        local a, b = pair()
        assert.truthy(a.Endorse(b.player, 2, false))
        pump()
        assert.are.equal(1, #a.db.records)
        assert.are.equal(1, #b.db.records)
        assert.are.equal(a.db.records[1].text, b.db.records[1].text)
        local rec = recordOf(a)
        assert.are.equal("Middle Foot", rec.endorsee.name)
        assert.are.equal("Player-4395-00000007", rec.endorsee.guid)
        assert.are.equal(2, rec.tags)
        assert.are.equal(1, rec.locationKind)
        assert.are.equal(230, rec.locationId)
        -- Proven: B's ack key signed the request and B's location.
        assert.are.equal(b.account.keyVersion, rec.ackKeyVersion)
        assert.are.equal(b.AckMac(b.keys.ack, rec.requestBytes, rec.ackLocationKind, rec.ackLocationId), rec.ackMac)
        assert.truthy(signedWith(a, rec, a.keys.real))
        assert.is_false(signedWith(a, rec, a.keys.drop))
        assert.are.equal("You endorsed Middle Foot \194\183 Calm.", a.chat[#a.chat])
        assert.are.equal(19, a.RealEndorsementsLeft(clock))
    end)

    it("signs a quiet endorsement with the drop key, says exactly the same, and doesn't use the daily cap", function()
        local a, b = pair()
        assert.truthy(a.Endorse(b.player, 2, true))
        pump()
        local rec = recordOf(a)
        assert.truthy(signedWith(a, rec, a.keys.drop))
        assert.is_false(signedWith(a, rec, a.keys.real))
        assert.are.equal("You endorsed Middle Foot \194\183 Calm.", a.chat[#a.chat])
        assert.are.equal(20, a.RealEndorsementsLeft(clock))
        assert.are.equal(1, #b.db.records) -- the endorsee gets it all the same
    end)

    it("finishes unproven after 15 seconds when the endorsee can't ack", function()
        local a = client("Corvina Ashby", "Player-4395-0A1B2C3D", codes.valid[1].input)
        local b = client("Middle Foot", "Player-4395-00000007", nil) -- has the addon, not linked
        assert.truthy(a.Endorse(b.player, 1, false))
        pump(10)
        assert.are.equal(0, #a.db.records) -- still waiting
        pump(10)
        local rec = recordOf(a)
        assert.are.equal(0, rec.ackKeyVersion)
        assert.are.equal(string.rep("\0", 8), rec.ackMac)
        assert.truthy(signedWith(a, rec, a.keys.real))
        assert.are.equal(1, #b.db.records)
    end)

    it("asks first when the endorsee chose \"ask\", and proves the record once they accept", function()
        local a, b = pair()
        b.SetAckMode("group", "ask")
        local asked
        b.AskToAck = function(request, bytes, sender) asked = { request = request, bytes = bytes, sender = sender } end
        a.Endorse(b.player, 4, false)
        pump(2)
        assert.is_table(asked)
        assert.are.equal("Corvina Ashby", asked.request.endorser.name)
        assert.are.equal(0, #a.db.records)
        b.SendAck(asked.request, asked.bytes, asked.sender)
        pump(2)
        assert.truthy(recordOf(a).ackKeyVersion > 0)
    end)

    it("gives an unproven record when an \"ask\" request is never accepted", function()
        local a, b = pair()
        b.SetAckMode("group", "ask")
        b.AskToAck = function() end
        a.Endorse(b.player, 4, false)
        pump(20)
        assert.are.equal(0, recordOf(a).ackKeyVersion)
    end)

    it("stops real endorsements at 20 a day, but quiet ones still go", function()
        local a, b = pair()
        a.db.dailyCounter = { day = os.date("!%Y-%m-%d", clock), used = 20 }
        local ok, message = a.Endorse(b.player, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("today's 20", 1, true))
        assert.truthy(a.Endorse(b.player, 1, true))
    end)

    it("refuses to endorse yourself, or anyone while unlinked", function()
        local a, b = pair()
        local ok, message = a.Endorse(a.player, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("yourself", 1, true))
        a.UnlinkAccount()
        ok, message = a.Endorse(b.player, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("/lfgplus setup", 1, true))
    end)

    it("never acks a request that names someone else or comes from someone other than the endorser", function()
        local a, b = pair()
        local c = client("Sir Rocky", "Player-4395-00000099", codes.valid[3].input)
        -- A request from A for B, replayed to C: names B, so C refuses it.
        a.Endorse(b.player, 1, false)
        local q = net[1].message
        net = {}
        c.OnAddonMessage(q, "Corvina Ashby", "WHISPER")
        -- The same request delivered to B but claiming to come from C: wrong sender.
        b.OnAddonMessage(q, "Sir Rocky", "WHISPER")
        assert.are.equal(0, #net) -- nobody acked
    end)

    it("holds messages during combat and sends them when it ends", function()
        local a, b = pair()
        combat = true
        a.Endorse(b.player, 1, false)
        assert.are.equal(0, #net)
        assert.are.equal(1, a.QueuedMessages())
        -- A fight longer than the ack timeout: the wait starts when the request goes out, so nothing times out yet.
        advance(30)
        assert.are.equal(0, #a.db.records)
        combat = false
        a.ResumeSending()
        assert.are.equal(1, #net)
        pump()
        assert.truthy(recordOf(a).ackKeyVersion > 0)
    end)

    it("uses strictly increasing counters seeded from the clock", function()
        local a, b = pair()
        local c = client("Sir Rocky", "Player-4395-00000099", codes.valid[3].input)
        party["Sir Rocky"] = true
        a.Endorse(b.player, 1, false)
        a.Endorse(c.player, 1, false)
        pump()
        -- Records are stored in the order acks arrive, so compare the set of counters.
        local c1, c2 = recordOf(a, 1).counter, recordOf(a, 2).counter
        local low, high = math.min(c1, c2), math.max(c1, c2)
        assert.are.equal(low + 1, high)
        assert.are.equal(high, a.db.lastCounter)
        assert.truthy(low >= clock - 1767225600 - 30)
    end)

    it("stores a delivered record once, however often it arrives", function()
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        pump()
        local r = "R:" .. b.ToBase64Url(b.RecordFromText(b.db.records[1].text))
        b.OnAddonMessage(r, "Corvina Ashby", "WHISPER")
        b.OnAddonMessage(r, "Corvina Ashby", "WHISPER")
        assert.are.equal(1, #b.db.records)
    end)

    it("refuses a second endorsement of the same player while the first is still waiting", function()
        local a, b = pair()
        assert.truthy(a.Endorse(b.player, 1, false))
        local ok, message = a.Endorse(b.player, 2, false)
        assert.is_false(ok)
        assert.truthy(message:find("Already endorsing", 1, true))
    end)

    it("endorses each player once, ever, once confirmed, whether it was real or quiet, and says the same either way", function()
        for _, quiet in ipairs({ false, true }) do
            local a, b = pair()
            assert.is_false(a.AlreadyEndorsed(b.player))
            assert.truthy(a.Endorse(b.player, 2, quiet))
            pump()
            assert.truthy(a.AlreadyEndorsed(b.player))
            assert.are.same({ at = recordOf(a).endorsedAt, tags = 2, proven = true }, a.db.endorsed[b.player.key])
            assert.truthy(a.EndorsementFinal(b.player))
            clock = clock + 400 * 86400 -- long after the record has faded on the site
            for _, again in ipairs({ false, true }) do
                local ok, message = a.Endorse(b.player, 1, again)
                assert.is_false(ok)
                assert.are.equal("You've already endorsed Middle Foot.", message)
            end
            assert.is_false(a.AlreadyEndorsed(nil))
            assert.are.equal(1, #a.db.records)
        end
    end)

    it("lets a confirmed endorsement replace one their addon never confirmed, and nothing replace a confirmed one", function()
        local a = client("Corvina Ashby", "Player-4395-0A1B2C3D", codes.valid[1].input)
        local b = client("Middle Foot", "Player-4395-00000007", nil) -- has the addon, not linked: can't confirm
        party["Corvina Ashby"], party["Middle Foot"] = true, true
        assert.truthy(a.Endorse(b.player, 2, false))
        pump(20)
        local first = recordOf(a, 1)
        assert.are.same({ at = first.endorsedAt, tags = 2, proven = false }, a.db.endorsed[b.player.key])
        assert.truthy(a.AlreadyEndorsed(b.player))
        assert.is_false(a.EndorsementFinal(b.player))

        -- Unconfirmed again: allowed, but the site keeps the first, so this install still shows the first.
        clock = clock + 86400
        assert.truthy(a.Endorse(b.player, 4, false))
        pump(20)
        assert.are.equal(0, recordOf(a, 2).ackKeyVersion)
        assert.are.same({ at = first.endorsedAt, tags = 2, proven = false }, a.db.endorsed[b.player.key])

        -- They link their account: the next endorsement is confirmed and replaces the first.
        assert(b.LinkAccount(codes.valid[2].input))
        clock = clock + 86400
        assert.truthy(a.Endorse(b.player, 8, true))
        pump()
        local third = recordOf(a, 3)
        assert.truthy(third.ackKeyVersion > 0)
        assert.are.same({ at = third.endorsedAt, tags = 8, proven = true }, a.db.endorsed[b.player.key])
        local ok, message = a.Endorse(b.player, 1, false)
        assert.is_false(ok)
        assert.are.equal("You've already endorsed Middle Foot.", message)
        assert.are.equal(3, #a.db.records)
    end)

    it("refuses to endorse in an unsupported region, without its own identity, or with no target", function()
        local a, b = pair()
        _G.GetCurrentRegion = function() return 5 end -- China
        local ok, message = a.Endorse(b.player, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("region", 1, true))
        _G.GetCurrentRegion = function() return 1 end
        ok, message = a.Endorse(nil, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("Target another player", 1, true))
        assert.is_false((a.Endorse({ realm = "" }, 1, false)))
        a.player = nil
        _G.UnitExists = function() return false end
        ok, message = a.Endorse(b.player, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("couldn't read your own character", 1, true))
        _G.UnitExists = nil
        assert.are.equal(0, #net)
    end)

    it("refuses an endorsement without exactly one known tag, and a name too long to encode", function()
        local a, b = pair()
        for _, tags in ipairs({ 0, 3, 9, 16, "x" }) do
            local refused, why = a.Endorse(b.player, tags, false)
            assert.is_false(refused)
            assert.truthy(why:find("Pick what they did best", 1, true))
        end
        assert.is_false(a.Endorse(b.player, nil, false))
        assert.are.equal(0, #net)
        assert.truthy(a.Endorse(b.player, 4, false))
        pump()
        assert.are.equal(4, recordOf(a).tags)
        local ok, message = a.Endorse({ name = string.rep("x", 65), realm = "", key = "x65" }, 1, false)
        assert.is_false(ok)
        assert.truthy(message:find("couldn't endorse", 1, true))
        assert.truthy(logged(a, "couldn't encode a request"))
        assert.are.equal(19, a.RealEndorsementsLeft(clock)) -- the failed one used nothing
    end)

    it("refuses up front an endorsement whose record wouldn't fit one addon message, using nothing up", function()
        local a = pair()
        net, wire = {}, {}
        -- Corvina Ashby's request with this endorsee is 61 bytes plus the endorsee's name and realm; the record adds
        -- 28, and "R:" with its base64url must stay within 255 bytes: 100 bytes of name and realm fit, 101 don't.
        local long = { name = string.rep("x", 64), realm = string.rep("y", 37), key = "long" }
        local ok, message = a.Endorse(long, 1, false)
        assert.is_false(ok)
        assert.are.equal("LFG+ can't endorse " .. long.name .. ": your names are too long to fit in one message.", message)
        assert.truthy(logged(a, "needs a 256-byte message; the limit is 255"))
        assert.is_nil(next(a.PendingEndorsements()))
        assert.are.equal(20, a.RealEndorsementsLeft(clock))
        assert.are.equal(0, #net)
        -- Exactly at the limit: endorsed, and both messages go out whole.
        local fits = { name = string.rep("x", 64), realm = string.rep("y", 36), key = "fits" }
        assert.truthy(a.Endorse(fits, 1, false))
        pump(20)
        local sizes = {}
        for _, m in ipairs(wire) do sizes[#sizes + 1] = m.kind .. m.bytes end
        assert.are.same({ "Q:217", "R:254", "R:254" }, sizes)
    end)

    it("ignores its own timeout once the ack has arrived", function()
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        pump(20)
        assert.are.equal(1, #a.db.records)
        assert.truthy(recordOf(a).ackKeyVersion > 0)
        a.TimeoutEndorsement(recordOf(a).counter) -- already finished: nothing to do
        assert.are.equal(1, #a.db.records)
    end)

    it("ignores acks that are malformed, match nothing pending, or come from someone else", function()
        local a, b = pair()
        a.OnAddonMessage("A:!!!", "Middle Foot", "WHISPER")
        a.OnAddonMessage("A:" .. a.ToBase64Url(string.rep("\0", 19)), "Middle Foot", "WHISPER")
        a.Endorse(b.player, 1, false)
        local q = table.remove(net, 1)
        b.OnAddonMessage(q.message, "Corvina Ashby", "WHISPER")
        local ack = table.remove(net, 1)
        assert.are.equal("A:", ack.message:sub(1, 2))
        a.OnAddonMessage(ack.message, "Sir Rocky", "WHISPER") -- B's ack, claimed by C
        assert.are.equal(0, #a.db.records)
        assert.truthy(logged(a, "malformed ack"))
        assert.truthy(logged(a, "matches no pending endorsement"))
        assert.truthy(logged(a, "not Middle Foot; ignored"))
        pump(20)
        assert.are.equal(0, recordOf(a).ackKeyVersion) -- finished unproven by the timeout
    end)

    it("treats an ack with key version 0 as unproven", function()
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        net = {}
        local counter = next(a.PendingEndorsements())
        a.OnAddonMessage("A:" .. a.ToBase64Url(counterBytes(counter) .. string.rep("\0", 15)), "Middle Foot", "WHISPER")
        local rec = recordOf(a)
        assert.are.equal(0, rec.ackKeyVersion)
        assert.are.equal(string.rep("\0", 8), rec.ackMac)
    end)

    it("keeps the endorsee's own location in the ack when it differs from ours", function()
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        _G.GetInstanceInfo = function() return "Blackrock Spire", "party", 1, "Normal", 5, 0, false, 229 end
        pump()
        local rec = recordOf(a)
        assert.are.equal(230, rec.locationId)
        assert.are.equal(229, rec.ackLocationId)
        assert.truthy(rec.ackKeyVersion > 0)
        assert.truthy(logged(a, "we saw 1:230"))
    end)

    it("records the map outside an instance, and no place when the client knows none", function()
        local a = pair()
        _G.GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        _G.C_Map = { GetBestMapForUnit = function() return 1429 end }
        assert.are.same({ 2, 1429 }, { a.CurrentLocation() })
        _G.C_Map = nil
        assert.are.same({ 0, 0 }, { a.CurrentLocation() })
    end)

    it("refuses requests for another game version, region or time, for another GUID, or before it knows itself", function()
        local a, b = pair()
        local function request(changes)
            local r = {
                gameVersion = 40, region = 1, keyVersion = 1, endorserAccount = a.account.accountId, counter = 5,
                endorsedAt = clock, locationKind = 1, locationId = 230,
                endorser = { name = "Corvina Ashby", realm = "" },
                endorsee = { name = "Middle Foot", realm = "", guid = "Player-4395-00000007" },
            }
            for k, v in pairs(changes or {}) do r[k] = v end
            return assert(a.EncodeRequest(r))
        end
        local function why(bytes) return select(2, b.CheckRequest(bytes, "Corvina Ashby", clock)) end
        assert.is_table(b.CheckRequest(request(), "Corvina Ashby", clock))
        assert.are.equal("malformed", why("nonsense"))
        assert.are.equal("another game version", why(request({ gameVersion = 10 })))
        assert.are.equal("another region", why(request({ region = 2 })))
        assert.are.equal("time too far from ours", why(request({ endorsedAt = clock - 301 })))
        assert.are.equal("GUID isn't ours", why(request({ endorsee = { name = "Middle Foot", realm = "", guid = "Player-4395-00000008" } })))
        b.player = nil
        _G.UnitExists = function() return false end
        assert.are.equal("own identity unknown", why(request()))
        _G.UnitExists = nil
    end)

    it("ignores a sender's seventh request within a minute, and forgets requests older than that", function()
        local _, b = pair()
        for _ = 1, 6 do b.OnAddonMessage("Q:x", "Corvina Ashby", "WHISPER") end
        assert.is_false(logged(b, "too many requests"))
        b.OnAddonMessage("Q:x", "Corvina Ashby", "WHISPER")
        assert.truthy(logged(b, "too many requests"))
        advance(61)
        b.Log.Clear()
        b.OnAddonMessage("Q:x", "Corvina Ashby", "WHISPER")
        assert.is_false(logged(b, "too many requests"))
        assert.truthy(logged(b, "ignored a request from Corvina Ashby: malformed"))
    end)

    it("never acks once unlinked, even when the player accepts an \"ask first\" request", function()
        local a, b = pair()
        b.SetAckMode("group", "ask")
        local asked
        b.AskToAck = function(request, bytes, sender) asked = { request, bytes, sender } end
        a.Endorse(b.player, 4, false)
        pump(1)
        assert.is_table(asked)
        b.UnlinkAccount()
        b.SendAck(asked[1], asked[2], asked[3])
        assert.are.equal(0, #net)
    end)

    it("ignores records that are malformed, name someone else, or come from someone other than the endorser", function()
        local a, b = pair()
        local c = client("Sir Rocky", "Player-4395-00000099", codes.valid[3].input)
        b.OnAddonMessage("R:!!!", "Corvina Ashby", "WHISPER")
        assert.truthy(logged(b, "malformed record"))
        a.Endorse(b.player, 1, false)
        pump()
        local r = "R:" .. b.ToBase64Url(b.RecordFromText(b.db.records[1].text))
        c.OnAddonMessage(r, "Corvina Ashby", "WHISPER") -- names B, not C
        assert.are.equal(0, #c.db.records)
        assert.truthy(logged(c, "wrong endorsee or sender"))
        b.db.records = {}
        b.OnAddonMessage(r, "Sir Rocky", "WHISPER") -- B's record, but sent by C rather than the endorser
        assert.are.equal(0, #b.db.records)
        assert.truthy(logged(b, "wrong endorsee or sender"))
    end)

    it("tells guild members, friends, Battle.net friends and everyone else apart for the ack setting", function()
        local _, b = pair()
        local c = client("Sir Rocky", "Player-4395-00000099", codes.valid[3].input)
        local id = { name = "Sir Rocky", realm = "", guid = "Player-4395-00000099", key = "sir rocky" }
        assert.are.equal("others", b.RelationOf(id))
        _G.C_BattleNet = { GetGameAccountInfoByGUID = function(guid) return guid == id.guid and {} or nil end }
        assert.are.equal("friends", b.RelationOf(id))
        _G.C_FriendList = { IsFriend = function(guid) return guid == id.guid end }
        assert.are.equal("friends", b.RelationOf(id))

        -- A friend outside the group, with "ask first" for friends: B is asked.
        b.SetAckMode("friends", "ask")
        local asked
        b.AskToAck = function(request) asked = request end
        c.Endorse(b.player, 1, false)
        pump(1)
        assert.are.equal("Sir Rocky", asked.endorser.name)

        _G.C_GuildInfo = { MemberExistsByName = function(name) return name == "Sir Rocky" end }
        assert.are.equal("guild", b.RelationOf(id))
        _G.IsGuildMember = function(guid) return guid == id.guid end
        assert.are.equal("guild", b.RelationOf(id))
        party["Sir Rocky"] = true
        assert.are.equal("group", b.RelationOf(id))
        _G.C_BattleNet, _G.C_FriendList, _G.C_GuildInfo, _G.IsGuildMember = nil, nil, nil, nil
    end)

    it("prunes records older than 35 days, counts what it holds, and lists settings without the data add-on", function()
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        pump()
        assert.are.same({ 1, 0, 0 }, { a.RecordCounts() })
        assert.are.same({ 0, 1, 0 }, { b.RecordCounts() })
        b.db.records[2] = { dir = "received", text = "LFGR1:old", at = clock - 36 * 86400 }
        b.PruneRecords(clock)
        assert.are.equal(1, #b.db.records)
        assert.truthy(logged(b, "pruned 1 records"))
        assert.are.equal(3, #a.StatusLines()) -- Data.lua isn't loaded here: no data line
    end)

    -- ─── The group channel ───────────────────────────────────────────

    it("also sends a finished record to the group channel, once: the raid's, the instance group's or the party's", function()
        for _, channel in ipairs({ "PARTY", "RAID", "INSTANCE_CHAT" }) do
            wire = {}
            local a, b = pair()
            group = channel
            assert.truthy(a.Endorse(b.player, 2, false))
            pump()
            local whispered, heard = {}, {}
            for _, m in ipairs(wire) do
                if m.kind == "R:" then table.insert(m.channel == "WHISPER" and whispered or heard, m) end
            end
            assert.are.same({ { from = "Corvina Ashby", to = "Middle Foot", channel = "WHISPER", kind = "R:", bytes = whispered[1].bytes } }, whispered)
            assert.are.same({ { from = "Corvina Ashby", channel = channel, kind = "R:", bytes = whispered[1].bytes } }, heard)
            assert.truthy(logged(a, "sent R: to " .. channel))
        end
    end)

    it("sends nothing to a group channel when not in a group", function()
        local a, b = pair()
        group = nil
        assert.truthy(a.Endorse(b.player, 2, false))
        pump()
        assert.are.equal(1, #b.db.records) -- the whisper still arrives
        for _, m in ipairs(wire) do assert.are.equal("WHISPER", m.channel) end
    end)

    it("sends a real and a quiet endorsement in exactly the same way, proven or not, grouped or not", function()
        local function shapeOf(quiet, channel, linked)
            clock, timers, net, wire, clients, party = 1794096000, {}, {}, {}, {}, {}
            local a = client("Corvina Ashby", "Player-4395-0A1B2C3D", codes.valid[1].input)
            local b = client("Middle Foot", "Player-4395-00000007", linked and codes.valid[2].input or nil)
            local c = client("Sir Rocky", "Player-4395-00000099", codes.valid[3].input)
            party["Corvina Ashby"], party["Middle Foot"], party["Sir Rocky"] = true, true, true
            group = channel
            watchToasts(b)
            assert.truthy(a.Endorse(b.player, 2, quiet))
            pump(20)
            -- What each addon ends up holding is part of the shape too.
            return { wire = wire, endorser = { a.RecordCounts() }, endorsee = { b.RecordCounts() }, onlooker = { c.RecordCounts() },
                toasts = #b.toasts }
        end
        for _, channel in ipairs({ "PARTY", "RAID", "INSTANCE_CHAT", false }) do
            for _, linked in ipairs({ true, false }) do
                local real, quiet = shapeOf(false, channel or nil, linked), shapeOf(true, channel or nil, linked)
                assert.are.same(real, quiet)
                -- Q, A when the endorsee can confirm, R whispered, R to the group when there is one.
                assert.are.equal(2 + (linked and 1 or 0) + (channel and 1 or 0), #real.wire)
                assert.are.same({ 0, 0, channel and 1 or 0 }, real.onlooker)
            end
        end
    end)

    it("ignores its own record coming back on the group channel", function()
        local a, b = pair()
        a.Endorse(b.player, 2, false)
        pump()
        assert.are.same({ 1, 0, 0 }, { a.RecordCounts() })
        -- Even when someone else repeats it.
        a.OnAddonMessage("R:" .. a.ToBase64Url(a.RecordFromText(a.db.records[1].text)), "Middle Foot", "PARTY")
        assert.are.same({ 1, 0, 0 }, { a.RecordCounts() })
        assert.is_false(logged(a, "ignored record"))
        assert.is_false(logged(a, "carrying record"))
    end)

    it("stores the endorsee's record once and shows one toast, whichever copy arrives first", function()
        local a, b = pair()
        watchToasts(b)
        a.Endorse(b.player, 2, false)
        pump()
        assert.are.same({ 0, 1, 0 }, { b.RecordCounts() })
        assert.are.equal(1, #b.toasts)
        -- The other way round: heard in the group first, whispered after.
        local r = "R:" .. b.ToBase64Url(b.RecordFromText(b.db.records[1].text))
        b.db.records, b.toasts = {}, {}
        b.OnAddonMessage(r, "Corvina Ashby", "RAID")
        b.OnAddonMessage(r, "Corvina Ashby", "WHISPER")
        assert.are.same({ 0, 1, 0 }, { b.RecordCounts() })
        assert.are.equal("received", b.db.records[1].dir)
        assert.are.equal(1, #b.toasts)
    end)

    it("carries a copy of a record between two other players in the group, and adds it to the upload", function()
        local a, b = pair()
        local c = third()
        watchToasts(c)
        a.Endorse(b.player, 2, false)
        pump()
        assert.are.same({ { text = a.db.records[1].text, at = recordOf(a).endorsedAt, account = a.account.accountId,
            counter = recordOf(a).counter, proven = true, seq = 1 } }, c.db.carried)
        assert.are.same({ 0, 0, 1 }, { c.RecordCounts() })
        assert.are.equal(0, #c.toasts)
        assert.are.same({ a.db.records[1].text }, c.UploadLines())
        assert.are.equal("Waiting to upload: 0 given, 0 received, 1 from your groups.", c.WaitingLine())
        assert.truthy(logged(c, "carrying record"))
        -- The two players it's between hold it as their own, and carry nothing.
        assert.are.equal(0, #a.db.carried)
        assert.are.equal(0, #b.db.carried)
        assert.are.equal("Waiting to upload: 1 given, 0 received.", a.WaitingLine())
    end)

    it("carries nothing it can't decode, that its endorser didn't send, or that was only whispered", function()
        pair()
        local c = third()
        local r = heardRecord(c)
        c.OnAddonMessage("R:!!!", "Corvina Ashby", "PARTY")
        assert.truthy(logged(c, "malformed record"))
        c.OnAddonMessage(r, "Middle Foot", "PARTY") -- Corvina's record, sent by someone else
        c.OnAddonMessage(r, nil, "PARTY")
        assert.truthy(logged(c, "wrong endorsee or sender"))
        c.OnAddonMessage(r, "Corvina Ashby", "WHISPER") -- a whispered record must name us
        assert.are.equal(0, #c.db.carried)
        c.OnAddonMessage(r, "Corvina Ashby", "PARTY")
        assert.are.equal(1, #c.db.carried)
    end)

    it("carries only records inside the upload window: not older than it keeps its own, not ahead of the clock", function()
        pair()
        local c = third()
        local function hear(counter, endorsedAt)
            c.OnAddonMessage(heardRecord(c, { counter = counter, endorsedAt = endorsedAt }), "Corvina Ashby", "PARTY")
            return #c.db.carried
        end
        assert.are.equal(0, hear(1, clock - 35 * 86400 - 1))
        assert.are.equal(0, hear(2, clock + 301))
        assert.truthy(logged(c, "not carrying record 1 from Corvina Ashby: its time is outside the upload window"))
        assert.truthy(logged(c, "not carrying record 2 from Corvina Ashby"))
        assert.are.equal(1, hear(3, clock - 35 * 86400))
        assert.are.equal(2, hear(4, clock + 300))
    end)

    it("carries at most 20 records a minute from one sender", function()
        pair()
        local c = third()
        for counter = 1, 20 do c.OnAddonMessage(heardRecord(c, { counter = counter }), "Corvina Ashby", "PARTY") end
        assert.are.equal(20, #c.db.carried)
        assert.is_false(logged(c, "too many records"))
        c.OnAddonMessage(heardRecord(c, { counter = 21 }), "Corvina Ashby", "PARTY")
        assert.are.equal(20, #c.db.carried)
        assert.truthy(logged(c, "too many records from Corvina Ashby"))
        -- Another sender has their own allowance, and a minute later so does the first again.
        local other = { name = "Middle Foot", realm = "", guid = "Player-4395-00000007" }
        c.OnAddonMessage(heardRecord(c, { counter = 22, endorser = other, endorsee = { name = "Corvina Ashby", realm = "" } }), "Middle Foot", "PARTY")
        assert.are.equal(21, #c.db.carried)
        advance(61)
        c.OnAddonMessage(heardRecord(c, { counter = 23 }), "Corvina Ashby", "PARTY")
        assert.are.equal(22, #c.db.carried)
    end)

    it("carries a record once, and never one it already holds as its own", function()
        pair()
        local c = third()
        local r, text = heardRecord(c)
        c.OnAddonMessage(r, "Corvina Ashby", "PARTY")
        c.OnAddonMessage(r, "Corvina Ashby", "RAID")
        assert.are.same({ { text = text, at = clock, account = string.rep("0", 31) .. "9", counter = 7, proven = false, seq = 1 } },
            c.db.carried)
        -- The same endorser and counter as one of our own records: ours stays the only copy, whatever the rest says.
        c.db.carried = {}
        c.db.records = {
            { dir = "received", text = "LFGR1:other", at = clock, account = string.rep("0", 31) .. "9", counter = 6 },
            { dir = "received", text = text, at = clock, account = string.rep("0", 31) .. "9", counter = 7 },
        }
        c.OnAddonMessage(r, "Corvina Ashby", "PARTY")
        c.OnAddonMessage(heardRecord(c, { locationId = 229 }), "Corvina Ashby", "PARTY")
        assert.are.equal(0, #c.db.carried)
        c.OnAddonMessage(heardRecord(c, { counter = 8 }), "Corvina Ashby", "PARTY")
        assert.are.equal(1, #c.db.carried)
    end)

    it("keeps at most 200 carried records, dropping the oldest, and prunes them with its own after 35 days", function()
        pair()
        local c = third()
        for i = 1, 200 do c.db.carried[i] = { text = "LFGR1:held" .. i, at = clock - 35 * 86400 + i } end
        local r, text = heardRecord(c)
        c.OnAddonMessage(r, "Corvina Ashby", "PARTY")
        assert.are.equal(200, #c.db.carried)
        assert.are.equal("LFGR1:held2", c.db.carried[1].text)
        assert.are.equal(text, c.db.carried[200].text)
        c.db.records = { { dir = "given", text = "LFGR1:mine", at = clock } }
        c.PruneRecords(clock + 100) -- held2..held99 are now past 35 days
        assert.are.equal(102, #c.db.carried)
        assert.are.equal("LFGR1:held100", c.db.carried[1].text)
        assert.are.equal(text, c.db.carried[102].text)
        assert.are.equal(1, #c.db.records)
        assert.truthy(logged(c, "pruned 0 records and 98 carried copies older than 35 days"))
        c.Log.Clear()
        c.PruneRecords(clock + 100) -- nothing left to prune: nothing logged
        assert.is_false(logged(c, "pruned"))
    end)

    it("takes the handshake from whispers only, and records from nowhere but a whisper or a group channel", function()
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        local q = table.remove(net, 1).message
        for _, channel in ipairs({ "PARTY", "RAID", "INSTANCE_CHAT", "GUILD" }) do b.OnAddonMessage(q, "Corvina Ashby", channel) end
        b.OnAddonMessage(q, "Corvina Ashby", nil)
        assert.are.equal(0, #net) -- no ack
        assert.truthy(logged(b, "ignored Q: on PARTY from Corvina Ashby"))
        assert.truthy(logged(b, "ignored Q: on nil from Corvina Ashby"))
        b.OnAddonMessage(q, "Corvina Ashby", "WHISPER")
        local ack = table.remove(net, 1).message
        assert.are.equal("A:", ack:sub(1, 2))
        a.OnAddonMessage(ack, "Middle Foot", "PARTY")
        assert.are.equal(0, #a.db.records) -- still waiting for a whispered ack
        assert.truthy(logged(a, "ignored A: on PARTY from Middle Foot"))
        a.OnAddonMessage(ack, "Middle Foot", "WHISPER")
        assert.truthy(recordOf(a).ackKeyVersion > 0)
        local c = third()
        for _, channel in ipairs({ "GUILD", "OFFICER", "CHANNEL", "SAY", "YELL" }) do c.OnAddonMessage(heardRecord(c), "Corvina Ashby", channel) end
        c.OnAddonMessage(heardRecord(c), "Corvina Ashby", nil)
        assert.are.equal(0, #c.db.carried)
        assert.truthy(logged(c, "ignored R: on GUILD from Corvina Ashby"))
    end)

    it("lists its own records first for upload, then carried ones, in parts of 500 the site takes whole", function()
        pair()
        local c = third()
        assert.are.same({}, c.UploadLines())
        assert.is_nil(c.WaitingLine())
        for i = 1, 2 do c.db.records[i] = { dir = "given", text = "LFGR1:own" .. i, at = clock } end
        for i = 1, 5 do c.db.carried[i] = { text = "LFGR1:carried" .. i, at = clock } end
        assert.are.same({ "LFGR1:own1", "LFGR1:own2", "LFGR1:carried1", "LFGR1:carried2", "LFGR1:carried3", "LFGR1:carried4",
            "LFGR1:carried5" }, c.UploadLines())
        assert.are.equal("Waiting to upload: 2 given, 0 received, 5 from your groups.", c.WaitingLine())
        assert.are.equal(1, #c.UploadParts())
        -- 498 of our own and 5 carried: 503 lines, every one of them kept, in a paste of 500 and one of 3.
        for i = 3, 498 do c.db.records[i] = { dir = "received", text = "LFGR1:own" .. i, at = clock } end
        local lines, parts = c.UploadLines(), c.UploadParts()
        assert.are.equal(503, #lines)
        assert.are.same({ 500, 3 }, { #parts[1], #parts[2] })
        assert.are.same({ "LFGR1:own498", "LFGR1:carried1", "LFGR1:carried2" }, { parts[1][498], parts[1][499], parts[1][500] })
        assert.are.same({ "LFGR1:carried3", "LFGR1:carried4", "LFGR1:carried5" }, parts[2])
        -- Exactly 500 is one paste.
        c.db.carried = {}
        for i = 499, 500 do c.db.records[i] = { dir = "received", text = "LFGR1:own" .. i, at = clock } end
        assert.are.equal(1, #c.UploadParts())
    end)

    -- ─── Late acks ───────────────────────────────────────────────────────────

    --- Corvina endorses Middle Foot, who asks first and doesn't answer in time: unproven. Returns both, Sir Rocky (who
    -- carries the record) and B's unanswered request, to answer later with b.SendAck(unpack(asked)).
    local function timedOut(quiet)
        local a, b = pair()
        local c = third()
        b.SetAckMode("group", "ask")
        local asked
        b.AskToAck = function(request, bytes, sender) asked = { request, bytes, sender } end
        watchToasts(b)
        assert.truthy(a.Endorse(b.player, 2, quiet))
        pump(20)
        assert.are.equal(0, recordOf(a).ackKeyVersion)
        return a, b, c, asked
    end

    --- True when no log line names an endorsement quiet or real.
    local function logSaysNothingOfQuiet(ns)
        for _, line in ipairs(ns.Log.Recent(2000)) do
            if line:find("%f[%a]quiet%f[%A]") or line:find("%f[%a]real%f[%A]") then return false end
        end
        return true
    end

    it("proves a timed-out endorsement when the ack comes later, real or quiet alike, saying and using nothing more", function()
        for _, quiet in ipairs({ false, true }) do
            local a, b, c, asked = timedOut(quiet)
            local first = recordOf(a)
            local said, left = #a.chat, a.RealEndorsementsLeft(clock)
            assert.are.same({ 0, 1, 0 }, { b.RecordCounts() })
            assert.are.equal(1, #b.toasts)
            assert.are.equal(1, #c.db.carried)
            assert.is_false(c.db.carried[1].proven)
            assert.is_table(a.db.lateAcks[first.counter])

            advance(3600) -- an hour on, Middle Foot accepts
            wire = {}
            b.SendAck(unpack(asked))
            pump()
            local rec = recordOf(a)
            assert.are.equal(1, #a.db.records)
            assert.are.same({ first.counter, first.requestBytes, 2 }, { rec.counter, rec.requestBytes, rec.tags })
            assert.are.equal(b.account.keyVersion, rec.ackKeyVersion)
            assert.truthy(signedWith(a, rec, quiet and a.keys.drop or a.keys.real))
            assert.is_true(a.db.records[1].proven)
            assert.are.same({ at = first.endorsedAt, tags = 2, proven = true }, a.db.endorsed[b.player.key])
            assert.are.equal(said, #a.chat)                      -- nothing printed again
            assert.are.equal(left, a.RealEndorsementsLeft(clock)) -- no daily slot used again
            assert.is_nil(next(a.db.lateAcks))
            -- Sent again exactly like the first: whispered and to the group.
            local kinds = {}
            for _, m in ipairs(wire) do kinds[#kinds + 1] = m.from .. " " .. m.kind .. " " .. m.channel end
            assert.are.same({ "Middle Foot A: WHISPER", "Corvina Ashby R: WHISPER", "Corvina Ashby R: PARTY" }, kinds)
            -- The endorsee and the carrier swap their unproven copies for it; no second toast.
            assert.are.same({ 0, 1, 0 }, { b.RecordCounts() })
            assert.are.equal(a.db.records[1].text, b.db.records[1].text)
            assert.is_true(b.db.records[1].proven)
            assert.are.equal(1, #b.toasts)
            assert.truthy(logged(b, "received the proven copy of record " .. first.counter))
            assert.are.equal(1, #c.db.carried)
            assert.are.equal(a.db.records[1].text, c.db.carried[1].text)
            assert.is_true(c.db.carried[1].proven)
            assert.truthy(logged(c, "carrying the proven copy of record " .. first.counter))
            assert.truthy(logSaysNothingOfQuiet(a))
            -- The same ack again: nothing left to prove.
            b.SendAck(unpack(asked))
            pump()
            assert.truthy(logged(a, "ack " .. first.counter .. " from Middle Foot matches no pending endorsement"))
            assert.are.equal(1, #a.db.records)
        end
    end)

    it("remembers timed-out endorsements for a day, also over a reload, and then forgets them", function()
        local a, b, _, asked = timedOut(false)
        local counter = recordOf(a).counter
        local saved = a.db.lateAcks[counter]
        assert.are.same({ name = "Middle Foot", realm = "", guid = "Player-4395-00000007", key = "middle foot" }, saved.target)
        assert.are.same({ 2, false, recordOf(a).endorsedAt }, { saved.tags, saved.quiet, saved.endorsedAt })
        -- A day and a bit later the ack is too late, and the next login forgets it.
        advance(86401)
        b.SendAck(unpack(asked))
        pump()
        assert.truthy(logged(a, "ack " .. counter .. " from Middle Foot matches no pending endorsement"))
        assert.are.equal(0, recordOf(a).ackKeyVersion)
        a.db.lateAcks[1] = { at = clock } -- a fresh one stays
        a.PruneRecords(clock)
        local kept = next(a.db.lateAcks)
        assert.are.equal(1, kept)
        assert.is_nil(next(a.db.lateAcks, kept))
        -- Finishing another unproven endorsement forgets the stale ones too.
        a.db.lateAcks = { [2] = { at = clock - 86401 } }
        local c = client("Sir Rocky", "Player-4395-00000099", nil)
        assert.truthy(a.Endorse(c.player, 1, false))
        pump(20)
        assert.is_nil(a.db.lateAcks[2])
        assert.is_table(a.db.lateAcks[recordOf(a, 2).counter])
    end)

    it("ignores a late ack that is unproven, from someone else, for a damaged copy, or after linking another setup code", function()
        local a, b, _, asked = timedOut(false)
        local counter = recordOf(a).counter
        local ack = "A:" .. a.ToBase64Url(counterBytes(counter) .. string.rep("\0", 15))
        a.OnAddonMessage(ack, "Middle Foot", "WHISPER") -- key version 0: still unproven
        assert.truthy(logged(a, "has key version 0; treating as unproven"))
        assert.is_table(a.db.lateAcks[counter])
        b.SendAck(unpack(asked))
        local real = table.remove(net, 1).message
        net = {}
        a.OnAddonMessage(real, "Sir Rocky", "WHISPER")
        assert.truthy(logged(a, "ack " .. counter .. " came from Sir Rocky, not Middle Foot; ignored"))
        -- Linked to another account, or another key version, or not at all: the old key can't sign it any more.
        for _, code in ipairs({ codes.valid[3].input, "unlinked" }) do
            a.Log.Clear()
            if code == "unlinked" then a.UnlinkAccount() else assert(a.LinkAccount(code)) end
            a.OnAddonMessage(real, "Middle Foot", "WHISPER")
            assert.truthy(logged(a, "late ack " .. counter .. " from Middle Foot: linked to another setup code since; not proven"))
        end
        assert(a.LinkAccount(codes.valid[1].input))
        a.account.keyVersion = a.account.keyVersion + 1
        a.OnAddonMessage(real, "Middle Foot", "WHISPER")
        assert.are.equal(0, recordOf(a).ackKeyVersion)
        a.account.keyVersion = a.account.keyVersion - 1
        -- A damaged saved copy matches nothing.
        a.db.lateAcks[counter].request = "!!!"
        a.OnAddonMessage(real, "Middle Foot", "WHISPER")
        assert.are.equal(0, recordOf(a).ackKeyVersion)
        a.db.lateAcks[counter].request = nil
        a.OnAddonMessage(real, "Middle Foot", "WHISPER")
        assert.are.equal(0, recordOf(a).ackKeyVersion)
    end)

    it("logs where a late ack's endorsee saw itself when it differs, and still proves the record", function()
        local a, b, _, asked = timedOut(false)
        _G.GetInstanceInfo = function() return "Blackrock Spire", "party", 1, "Normal", 5, 0, false, 229 end
        b.SendAck(unpack(asked))
        pump()
        assert.are.equal(229, recordOf(a).ackLocationId)
        assert.truthy(logged(a, "we saw 1:230"))
    end)

    it("swaps in only a proven copy of the same request: never an unproven one, nor another record with that counter", function()
        local a, b = pair()
        local c = third()
        local base = { endorser = { name = "Corvina Ashby", realm = "", guid = "Player-4395-0A1B2C3D" }, counter = 7 }
        --- An "R:" for record 7 between Corvina and `to`, unproven or with a made-up ack, at `locationId`.
        local function record(to, proven, locationId)
            local r = { gameVersion = 40, region = 1, keyVersion = 1, endorserAccount = a.account.accountId,
                counter = base.counter, endorsedAt = clock, locationKind = 1, locationId = locationId or 230,
                endorser = base.endorser, endorsee = to }
            local ack = proven and { ackKeyVersion = 1, ackLocationKind = 1, ackLocationId = 230, ackMac = "12345678" } or a.UNPROVEN_ACK
            return "R:" .. a.ToBase64Url(a.EncodeRecord(assert(a.EncodeRequest(r)), ack, 2, a.keys.real))
        end
        local foot = { name = "Middle Foot", realm = "", guid = "Player-4395-00000007" }
        watchToasts(b)
        b.OnAddonMessage(record(foot, false), "Corvina Ashby", "WHISPER")
        b.OnAddonMessage(record(foot, true, 229), "Corvina Ashby", "WHISPER") -- the same counter, another request
        assert.is_false(b.db.records[1].proven)
        b.OnAddonMessage(record(foot, true), "Corvina Ashby", "WHISPER")
        assert.is_true(b.db.records[1].proven)
        assert.are.equal(1, #b.db.records)
        assert.are.equal(1, #b.toasts)
        b.OnAddonMessage(record(foot, false), "Corvina Ashby", "WHISPER") -- never back to unproven
        assert.is_true(b.db.records[1].proven)

        -- A carrier keeps another record with the same counter beside the first, and swaps only the same request.
        c.OnAddonMessage(record(foot, false), "Corvina Ashby", "PARTY")
        c.OnAddonMessage(record(foot, true, 229), "Corvina Ashby", "PARTY")
        assert.are.same({ false, true }, { c.db.carried[1].proven, c.db.carried[2].proven })
        c.OnAddonMessage(record(foot, true), "Corvina Ashby", "PARTY")
        assert.are.equal(2, #c.db.carried)
        assert.are.same({ true, true }, { c.db.carried[1].proven, c.db.carried[2].proven })
        assert.are.equal(3, c.db.carried[1].seq) -- stored anew: waiting for upload again
        -- Another endorser's record with the same account and counter isn't the same request either.
        local other = { name = "Sir Pebbles", realm = "" }
        local before = #c.db.carried
        base.endorser = other
        c.OnAddonMessage(record(foot, false), "Sir Pebbles", "PARTY")
        assert.are.equal(before + 1, #c.db.carried)
    end)

    -- ─── Upload ──────────────────────────────────────────────────────────────

    it("offers for upload only what the site still takes, and counts as waiting only what isn't marked uploaded", function()
        pair()
        local c = third()
        local day = 86400
        c.db.records = {
            { dir = "given", text = "LFGR1:new", at = clock, seq = 3 },
            { dir = "received", text = "LFGR1:edge", at = clock - 30 * day + 3600, seq = 2 },
            { dir = "received", text = "LFGR1:old", at = clock - 30 * day + 3599 }, -- inside the hour's margin: left out
            { dir = "given", text = "LFGR1:legacy", at = clock },                   -- stored before numbering
        }
        c.db.carried = { { text = "LFGR1:carried", at = clock, seq = 5 }, { text = "LFGR1:stale", at = clock - 31 * day, seq = 6 } }
        assert.are.same({ "LFGR1:new", "LFGR1:edge", "LFGR1:legacy", "LFGR1:carried" }, c.UploadLines())
        assert.are.same({ 2, 1, 1 }, { c.WaitingCounts(clock) })
        assert.are.equal("Waiting to upload: 2 given, 1 received, 1 from your groups.", c.WaitingLine())
        assert.are.same({ 2, 2, 2 }, { c.RecordCounts() }) -- what's held, old or not
        c.MarkUploaded(3)
        assert.are.same({ 0, 0, 1 }, { c.WaitingCounts(clock) })
        assert.are.equal(4, #c.UploadLines()) -- still offered, to paste again
        c.MarkUploaded(1) -- never backwards
        assert.are.equal(3, c.db.uploadedSeq)
        c.MarkUploaded(5)
        assert.is_nil(c.WaitingLine())
        assert.truthy(logged(c, "marked everything up to 5 as uploaded"))
        -- New records are numbered on from there, and wait again.
        c.db.lastSeq = 6
        local r = heardRecord(c, { counter = 8 })
        c.OnAddonMessage(r, "Corvina Ashby", "PARTY")
        assert.are.equal(7, c.db.carried[#c.db.carried].seq)
        assert.are.equal("Waiting to upload: 0 given, 0 received, 1 from your groups.", c.WaitingLine())
    end)

    it("works on a client without C_Timer: sends at once and waits for the ack", function()
        _G.C_Timer = nil
        local a, b = pair()
        a.Endorse(b.player, 1, false)
        a.Send("Z:queued", "Middle Foot") -- no timer to space them out: sent straight away
        assert.are.equal(2, #net)
        pump()
        assert.truthy(recordOf(a).ackKeyVersion > 0)
        assert.is_nil(next(a.PendingEndorsements()))
        assert.truthy(logged(b, "unknown message kind \"Z\""))
    end)
end)

describe("the addon-message queue", function()
    local combat, ns, sent

    before_each(function()
        combat, sent = false, {}
        _G.CreateFrame = nil
        _G.LFGPlusLog = nil
        _G.date = os.date
        _G.GetServerTime = function() return 1794096000 end
        _G.C_Timer = { After = function() end } -- the queue drains only when a spec says so
        _G.InCombatLockdown = function() return combat end
        _G.UnitAffectingCombat = function() return combat end
        ns = loader.load({ "Core.lua", "Log.lua", "Comm.lua" })
        ns.db = ns.ApplyDefaults({}, ns.DEFAULTS)
        ns.Print = function() end
    end)

    local function logged(text)
        for _, line in ipairs(ns.Log.Recent(2000)) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    it("refuses a message longer than the client allows", function()
        ns.SendRaw = function(message) table.insert(sent, message); return true end
        assert.is_false(ns.Send(string.rep("x", 256), "Middle Foot"))
        assert.are.equal(0, #sent)
        assert.truthy(logged("message too long (256 bytes)"))
    end)

    it("holds at most 50 messages in combat, dropping the oldest", function()
        ns.SendRaw = function(message) table.insert(sent, message); return true end
        combat = true
        for i = 1, 51 do assert.truthy(ns.Send("Q:" .. i, "Middle Foot")) end
        assert.are.equal(50, ns.QueuedMessages())
        assert.truthy(logged("send queue full"))
        combat = false
        ns.ResumeSending()
        assert.are.same({ "Q:2" }, sent)
    end)

    it("tells a sender when its message leaves the queue, sent or dropped", function()
        ns.SendRaw = function(message) table.insert(sent, message); return true end
        local left = {}
        combat = true
        ns.Send("Q:first", "Middle Foot", function() table.insert(left, "first") end)
        for i = 2, 50 do ns.Send("Q:" .. i, "Middle Foot") end
        assert.are.same({}, left)
        ns.Send("Q:last", "Middle Foot", function() table.insert(left, "last") end) -- the queue is full: drops "first"
        assert.are.same({ "first" }, left)
        combat = false
        ns.ResumeSending()
        assert.are.same({ "first" }, left) -- only one message drains per call here; "last" is still queued
    end)

    it("sends through C_ChatInfo, an older client's global SendAddonMessage, or reports that neither exists", function()
        local calls = {}
        _G.C_ChatInfo = { SendAddonMessage = function(...) table.insert(calls, { "C_ChatInfo", ... }); return 0 end }
        assert.are.equal(0, ns.SendRaw("Q:x", "Middle Foot"))
        _G.C_ChatInfo = nil
        _G.SendAddonMessage = function(...) table.insert(calls, { "global", ... }); return true end
        assert.is_true(ns.SendRaw("Q:y", "Middle Foot"))
        _G.SendAddonMessage = nil
        assert.are.equal("no-api", ns.SendRaw("Q:z", "Middle Foot"))
        assert.are.same({ { "C_ChatInfo", "LFGPLUS", "Q:x", "WHISPER", "Middle Foot" },
            { "global", "LFGPLUS", "Q:y", "WHISPER", "Middle Foot" } }, calls)
    end)

    it("sends to a group channel through the same queue, with no target", function()
        local calls = {}
        _G.C_ChatInfo = { SendAddonMessage = function(...) table.insert(calls, { "C_ChatInfo", ... }); return 0 end }
        combat = true
        assert.truthy(ns.Send("R:x", nil, nil, "RAID"))
        assert.are.equal(1, ns.QueuedMessages()) -- held in combat like a whisper
        combat = false
        ns.ResumeSending()
        _G.C_ChatInfo = nil
        _G.SendAddonMessage = function(...) table.insert(calls, { "global", ... }); return true end
        assert.is_true(ns.SendRaw("R:y", nil, "PARTY"))
        _G.SendAddonMessage = nil
        assert.are.same({ { "C_ChatInfo", "LFGPLUS", "R:x", "RAID" }, { "global", "LFGPLUS", "R:y", "PARTY" } }, calls)
        assert.truthy(logged("sent R: to RAID (3 bytes), result 0"))
        assert.is_false(ns.Send("R:" .. string.rep("x", 254), nil, nil, "RAID"))
        assert.truthy(logged("message too long (256 bytes) for RAID"))
    end)

    it("picks the channel that reaches the group: the instance group's, the raid's, the party's, or none", function()
        local grouped, instance, raid = false, false, false
        _G.LE_PARTY_CATEGORY_INSTANCE = 2
        _G.IsInGroup = function(category)
            if category == 2 then return instance end
            return grouped
        end
        _G.IsInRaid = function() return raid end
        assert.is_nil(ns.GroupChannel())
        grouped = true
        assert.are.equal("PARTY", ns.GroupChannel())
        raid = true
        assert.are.equal("RAID", ns.GroupChannel())
        instance = true -- an LFG raid: "RAID" would address the raid we came from
        assert.are.equal("INSTANCE_CHAT", ns.GroupChannel())
        -- Clients that lack a piece: no instance category, no IsInRaid, no IsInGroup.
        _G.LE_PARTY_CATEGORY_INSTANCE = nil
        assert.are.equal("RAID", ns.GroupChannel())
        _G.IsInRaid = nil
        assert.are.equal("PARTY", ns.GroupChannel())
        _G.IsInGroup = nil
        assert.is_nil(ns.GroupChannel())
    end)

    it("ignores malformed messages and unknown message kinds", function()
        ns.OnAddonMessage("Z:abc", "Middle Foot", "WHISPER")
        ns.OnAddonMessage(nil, "Middle Foot", "WHISPER")
        assert.truthy(logged("unknown message kind \"Z\" from Middle Foot"))
        assert.truthy(logged("malformed message from Middle Foot"))
    end)
end)

describe("the addon-message queue's pacing and notices", function()
    local clock, timers, ns, sent, filters

    local function advance(seconds)
        local target = clock + seconds
        while true do
            table.sort(timers, function(a, b) return a.due < b.due end)
            local t = timers[1]
            if not t or t.due > target then break end
            table.remove(timers, 1)
            clock = math.max(clock, t.due)
            t.fn()
        end
        clock = target
    end

    local function load()
        ns = loader.load({ "Core.lua", "Log.lua", "Comm.lua" })
        ns.db = ns.ApplyDefaults({}, ns.DEFAULTS)
        ns.Print = function() end
    end

    before_each(function()
        clock, timers, sent, filters = 1000, {}, {}, {}
        _G.CreateFrame = nil
        _G.LFGPlusLog = nil
        _G.date = os.date
        _G.Enum = nil
        _G.ERR_CHAT_PLAYER_NOT_FOUND_S = nil
        _G.GetServerTime = function() return math.floor(clock) end
        _G.GetTime = function() return clock end
        _G.C_Timer = { After = function(s, fn) table.insert(timers, { due = clock + s, fn = fn }) end }
        _G.InCombatLockdown = function() return false end
        _G.UnitAffectingCombat = function() return false end
        _G.ChatFrame_AddMessageEventFilter = function(event, fn) filters[event] = fn end
        load()
    end)

    after_each(function()
        _G.GetTime, _G.ChatFrame_AddMessageEventFilter, _G.Enum, _G.ERR_CHAT_PLAYER_NOT_FOUND_S = nil, nil, nil, nil
    end)

    local function logged(text)
        for _, line in ipairs(ns.Log.Recent(2000)) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    it("tries a throttled message again a second later, first in line, for either kind of throttle", function()
        local answers = { 3, 8, true, true }
        ns.SendRaw = function(message)
            local answer = table.remove(answers, 1)
            if answer == true then table.insert(sent, { message, clock }) end
            return answer
        end
        ns.Send("Q:first", "Middle Foot")
        ns.Send("Q:second", "Middle Foot")
        assert.are.same({}, sent)
        assert.are.equal(2, ns.QueuedMessages())
        assert.truthy(logged("throttled Q: to Middle Foot, result 3; trying again in 1s"))
        advance(1)
        assert.truthy(logged("throttled Q: to Middle Foot, result 8"))
        advance(1)
        assert.are.same({ { "Q:first", 1002 } }, sent)
        advance(1)
        assert.are.same({ "Q:first", "Q:second" }, { sent[1][1], sent[2][1] })
    end)

    it("reads the throttle and lockdown answers from the client's enum when it has one", function()
        _G.Enum = { SendAddonMessageResult = { AddonMessageThrottle = 30, ChannelThrottle = 31, AddOnMessageLockdown = 32 } }
        load()
        local answers = { 30, 31, 32, 3 }
        ns.SendRaw = function() return table.remove(answers, 1) end
        ns.Send("Q:x", "Middle Foot")
        advance(1)
        assert.truthy(logged("result 31; trying again"))
        advance(1)
        assert.truthy(logged("held Q: for Middle Foot: addon messages are locked down"))
        ns.ResumeSending()
        assert.truthy(logged("sent Q: to Middle Foot (3 bytes), result 3")) -- 3 is no throttle here
    end)

    it("slows to one message a second after a burst of eight, and speeds up again once it's over", function()
        ns.SendRaw = function(message) table.insert(sent, { message, clock }); return true end
        for i = 1, 12 do ns.Send("Q:" .. i, "Middle Foot") end
        advance(30)
        local gaps = {}
        for i = 2, #sent do gaps[#gaps + 1] = math.floor((sent[i][2] - sent[i - 1][2]) * 10 + 0.5) / 10 end
        assert.are.same({ 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 1, 1, 1, 1 }, gaps)
        advance(30) -- quiet for a while: the next ones go at the normal pace
        sent = {}
        ns.Send("Q:a", "Middle Foot")
        ns.Send("Q:b", "Middle Foot")
        advance(5)
        assert.are.equal(0.3, math.floor((sent[2][2] - sent[1][2]) * 10 + 0.5) / 10)
    end)

    it("refuses an over-long message loudly, naming its kind", function()
        assert.is_false(ns.Send("R:" .. string.rep("x", 254), "Middle Foot"))
        assert.truthy(logged("message too long (256 bytes) for Middle Foot; R: not sent"))
        assert.are.equal(0, ns.QueuedMessages())
    end)

    it("shows the client's offline notice for someone we whispered once, however many chat frames show it", function()
        ns.SendRaw = function() return true end
        local filter = filters.CHAT_MSG_SYSTEM
        assert.is_function(filter)
        local notice = "No player named 'Corvina Ashby' is currently playing."
        local function hidden(text, lineId)
            return filter({}, "CHAT_MSG_SYSTEM", text, "", "", "", "", "", 0, 0, "", 0, lineId)
        end
        assert.is_false(hidden(notice, 1)) -- we never whispered them: not ours to hide
        ns.Send("Q:x", "Corvina Ashby")
        ns.Send("R:x", nil, nil, "PARTY") -- a group message isn't a whisper
        assert.is_false(hidden(notice, 2))  -- the request's notice
        assert.is_false(hidden(notice, 2))  -- the same notice in a second chat frame
        advance(16)
        ns.Send("R:x", "Corvina Ashby")
        assert.is_true(hidden(notice, 3))   -- the record's notice: hidden
        assert.is_false(hidden("No player named 'Sir Rocky' is currently playing.", 4))
        assert.is_false(hidden("You are now Away.", 5))
        assert.is_false(filter({}, "CHAT_MSG_SYSTEM", nil))
        -- Half a minute after the first notice, a new one shows again.
        advance(31)
        ns.Send("Q:y", "Corvina Ashby")
        assert.is_false(hidden(notice, 6))
        -- Without line ids, notices at the same moment are one notice shown in several frames.
        advance(31)
        ns.Send("Q:z", "Corvina Ashby")
        assert.is_false(hidden(notice, nil))
        assert.is_false(hidden(notice, nil))
        advance(1)
        assert.is_true(hidden(notice, nil))
    end)

    it("knows the offline notice in the client's own words, and hides nothing for a whisper long ago", function()
        _G.ERR_CHAT_PLAYER_NOT_FOUND_S = "Kein Spieler namens \"%s\" (offline)."
        ns.SendRaw = function() return true end
        ns.Send("Q:x", "Sölvi-TwistingNether")
        local filter = filters.CHAT_MSG_SYSTEM
        local notice = "Kein Spieler namens \"sölvi-twistingnether\" (offline)."
        assert.is_false(filter({}, "CHAT_MSG_SYSTEM", notice, "", "", "", "", "", 0, 0, "", 0, 1))
        assert.is_true(filter({}, "CHAT_MSG_SYSTEM", notice, "", "", "", "", "", 0, 0, "", 0, 2))
        advance(60)
        assert.is_false(filter({}, "CHAT_MSG_SYSTEM", notice, "", "", "", "", "", 0, 0, "", 0, 3))
    end)

    it("registers no chat filter on a client without one", function()
        _G.ChatFrame_AddMessageEventFilter = nil
        filters = {}
        load()
        assert.is_nil(filters.CHAT_MSG_SYSTEM)
        assert.is_function(ns.FilterOfflineNotice)
    end)
end)
