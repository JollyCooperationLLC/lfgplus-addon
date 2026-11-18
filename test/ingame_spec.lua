-- The whole addon in a fake WoW Forever client, driven by events: runs and the post-run prompt, prompt clicks, the
-- endorsed toast, the upload box and the diagnostics snapshot. Frames are generic fakes (test/helpers/wow_stubs.lua),
-- so this proves the code paths run and the log stays free of errors; how they look is checked in game.
local stubs = require("test.helpers.wow_stubs")
local loader = require("test.helpers.load_addon")

local codes = loader.read_vectors("setup-code.json")
local records = loader.read_vectors("record-v1.json")
local BRD = { name = "Blackrock Depths", type = "party", id = 230 }

describe("in a WoW Forever client", function()
    local world, ns

    local function boot(options)
        _G.LFGPlusDB = options.saved
        options.interface = 16001
        options.units = options.units or {
            player = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            party1 = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" },
            party2 = { name = "Sir", realm = "Rocky", guid = "Player-4395-00000099" },
        }
        world = stubs.install(options)
        ns = world.loadAddon()
        world.fireAddonLoaded()
        world.fire("PLAYER_LOGIN")
    end

    local function frame(name)
        for _, f in ipairs(world.frames) do if f.name == name then return f end end
    end

    local function errors()
        local out = {}
        for _, e in ipairs(LFGPlusLog.entries) do if e.l == "E" then out[#out + 1] = e.m end end
        return out
    end

    local function logHas(text)
        for _, e in ipairs(LFGPlusLog.entries) do if e.m:find(text, 1, true) then return true end end
        return false
    end

    local function skilledButton()
        for _, f in ipairs(world.frames) do if f.text == "Skilled" and f.scripts.OnClick then return f end end
    end

    after_each(function()
        assert.are.same({}, errors())
        _G.LFGPlusDB = nil
    end)

    it("records client facts at login", function()
        boot({})
        local d = LFGPlusLog.diagnostics
        assert.are.equal("Middle | Foot", d.unitName)
        assert.are.equal("Player-4395-00000007", d.guid)
        assert.are.equal("40", d.gameVersion)
        assert.truthy(logHas("logged in as Middle Foot"))
        world.fire("GROUP_ROSTER_UPDATE")
        assert.truthy(logHas("member party1: UnitName = Corvina | Ashby, GUID = Player-4395-0A1B2C3D"))
    end)

    it("prompts ten minutes after leaving an instance with a boss kill, once, listing everyone who was in the group", function()
        boot({})
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.fire("ENCOUNTER_START", 227, "High Interrogator Gerstahn")
        world.fire("ENCOUNTER_END", 227, "High Interrogator Gerstahn", 1, 5, 1)
        world.instance = nil
        world.fire("ZONE_CHANGED_NEW_AREA")
        assert.is_nil(frame("LFGPlusPromptFrame")) -- stepping out isn't the end
        assert.truthy(logHas("left Blackrock Depths (dead: false); the run ends in 10 minutes unless we come back"))
        world.fire("ZONE_CHANGED_NEW_AREA") -- riding on: still the same wait
        world.advance(599)
        assert.is_nil(frame("LFGPlusPromptFrame"))
        world.advance(1)
        local prompt = frame("LFGPlusPromptFrame")
        assert.is_table(prompt)
        assert.truthy(prompt.shown)
        assert.are.equal("Endorse your group from Blackrock Depths", prompt.title.text)
        assert.are.same({ "Corvina Ashby", "Sir Rocky" }, { prompt.rows[1].name.text, prompt.rows[2].name.text })
        assert.truthy(logHas("run ended (10 minutes outside)"))
        assert.is_nil(ns.run)
        prompt:Hide()
        world.fire("ZONE_CHANGED_NEW_AREA")
        world.fire("GROUP_ROSTER_UPDATE")
        world.advance(1200)
        assert.is_false(prompt.shown) -- exactly once
    end)

    for _, account in ipairs({ "trial", "veteran" }) do
        it("tells a " .. account .. " account once that it can't endorse, and offers no prompt or endorsement", function()
            boot({ account = account, saved = { setupCode = codes.valid[2].input } })
            local said = 0
            for _, line in ipairs(world.chat) do if line:find("Trial accounts can't send", 1, true) then said = said + 1 end end
            assert.are.equal(1, said)
            assert.are.equal("true", LFGPlusLog.diagnostics[account == "trial" and "trialAccount" or "veteranTrialAccount"])
            world.instance = BRD
            world.fire("PLAYER_ENTERING_WORLD")
            world.fire("LFG_COMPLETION_REWARD")
            assert.is_nil(frame("LFGPlusPromptFrame"))
            assert.truthy(logHas("trial account: no prompt"))
            assert.are.same({ false, ns.TRIAL_TEXT }, { ns.Endorse(ns.UnitIdentity("party1"), 2) })
            assert.are.same({ false, ns.TRIAL_TEXT }, { ns.Endorse(ns.UnitIdentity("party1"), 2, true) }) -- quiet alike
        end)
    end

    it("treats a client without the trial-account functions as a full account", function()
        boot({ account = "old" })
        assert.is_false(ns.IsTrialAccount())
        assert.are.equal("<missing>", LFGPlusLog.diagnostics.trialAccount)
    end)

    it("doesn't prompt after leaving without a boss kill, or when the prompt is off", function()
        boot({})
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.instance = nil
        world.fire("ZONE_CHANGED_NEW_AREA")
        assert.is_nil(frame("LFGPlusPromptFrame"))
        ns.db.promptAfterRuns = false
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.fire("LFG_COMPLETION_REWARD")
        assert.is_nil(frame("LFGPlusPromptFrame"))
        assert.truthy(logHas("prompt is off"))
    end)

    it("waits for combat to end before showing the prompt", function()
        boot({})
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.inCombat = true
        world.fire("LFG_COMPLETION_REWARD")
        assert.is_nil(frame("LFGPlusPromptFrame"))
        world.fire("ENCOUNTER_END", 227, "High Interrogator Gerstahn", 1, 5, 0) -- the encounter ends; combat goes on
        assert.is_nil(frame("LFGPlusPromptFrame"))
        world.inCombat = false
        world.fire("PLAYER_REGEN_ENABLED")
        assert.truthy(frame("LFGPlusPromptFrame").shown)
    end)

    it("sends an endorsement request when a prompt button is clicked", function()
        boot({ saved = { setupCode = codes.valid[2].input } })
        SlashCmdList.LFGPLUS("group")
        local skilled
        for _, f in ipairs(world.frames) do if f.text == "Skilled" and f.scripts.OnClick then skilled = f; break end end
        assert.is_table(skilled)
        -- Every tag button carries its icon, tinted like its label, with the label beside it.
        local icons = {}
        for _, f in ipairs(world.frames) do
            if f.tag and f.icon then icons[f.text] = f.icon.texture end
        end
        assert.are.same({
            Fun = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Fun", Skilled = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Skilled",
            Helpful = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Helpful", Leader = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Leader",
        }, icons)
        assert.are.same({ 1, 0.82, 0 }, skilled.icon.vertexColor)
        assert.are.equal(skilled.icon, skilled:GetFontString().point[2])
        skilled.scripts.OnClick(skilled)
        assert.are.equal(1, #world.sent)
        assert.are.equal("LFGPLUS", world.sent[1].prefix)
        assert.are.equal("WHISPER", world.sent[1].channel)
        assert.are.equal("Corvina Ashby", world.sent[1].target)
        assert.are.equal("Q:", world.sent[1].message:sub(1, 2))
        world.advance(16) -- no ack: finishes unproven and delivers the record
        assert.are.equal(1, #ns.db.records)
        assert.are.equal("R:", world.sent[#world.sent].message:sub(1, 2))
    end)

    it("adds Endorse to other players' right-click menus, and the popup endorses them", function()
        boot({ saved = { setupCode = codes.valid[2].input } })
        for _, tag in ipairs(ns.UNIT_MENUS) do assert.are.equal(1, #world.menus[tag]) end
        local entries = world.openMenu("MENU_UNIT_PARTY", { unit = "party1", which = "PARTY" })
        assert.are.same({ "divider", "title", "button", "button" }, { entries[1].kind, entries[2].kind, entries[3].kind, entries[4].kind })
        assert.are.same({ "LFG+", "Endorse", "Copy LFG+ URL" }, { entries[2].text, entries[3].text, entries[4].text })
        entries[3].click()
        local popup = ns.EndorsePopup()
        assert.is_true(popup.shown)
        assert.are.equal("Endorse Corvina Ashby", popup.title.text)
        local skilled = popup.buttons[2]
        assert.are.equal("Skilled", skilled.text)
        skilled.scripts.OnClick(skilled)
        assert.are.equal("Corvina Ashby", world.sent[1].target)
        assert.are.equal("Q:", world.sent[1].message:sub(1, 2))
        assert.is_false(popup.shown) -- closes at once: the handshake carries on out of sight
        assert.truthy(logHas("popup click: Corvina Ashby tag 2 -> started"))
        world.advance(16) -- no ack: finishes unproven, and the popup stays closed
        assert.are.equal(1, #ns.db.records)
        assert.is_false(popup.shown)
        entries[3].click() -- opens again, ready for another click
        assert.is_true(popup.shown)
    end)

    it("offers its profile link, selected to copy, and lets the player close it", function()
        boot({})
        local entries = world.openMenu("MENU_UNIT_PARTY", { unit = "party1" })
        entries[4].click()
        assert.are.equal("LFGPLUS_COPY_URL", world.popups[#world.popups])
        local url = world.popupArgs[#world.popupArgs].data
        assert.are.equal("https://forever.lfg.plus/us/corvina-ashby", url)
        -- The dialog: the link in its box, selected and focused; Enter or Escape closes it.
        local dialog = StaticPopupDialogs.LFGPLUS_COPY_URL
        local box = { SetText = function(self, t) self.text = t end, HighlightText = function(self) self.selected = true end, SetFocus = function(self) self.focused = true end }
        dialog.OnShow({ editBox = box }, url)
        assert.are.same({ url, true, true }, { box.text, box.selected, box.focused })
        dialog.OnShow({}, url) -- a client whose dialog has no edit box: nothing to fill
        for _, key in ipairs({ "EditBoxOnEnterPressed", "EditBoxOnEscapePressed" }) do
            local hidden = false
            dialog[key]({ GetParent = function() return { Hide = function() hidden = true end } end })
            assert.is_true(hidden)
        end
    end)

    it("offers only the link for yourself, and leaves the menu alone without a unit or a link", function()
        boot({})
        local mine = world.openMenu("MENU_UNIT_PLAYER", { unit = "player" })
        assert.are.same({ "LFG+", "Copy LFG+ URL" }, { mine[2].text, mine[3].text })
        assert.are.equal(3, #mine)
        boot({ clientRegion = 5 }) -- no region, so no link; and nobody to endorse in yourself
        assert.are.same({}, world.openMenu("MENU_UNIT_PLAYER", { unit = "player" }))
        local noLink = world.openMenu("MENU_UNIT_PARTY", { unit = "party1" }) -- someone to endorse, but no link to copy
        assert.are.same({ 3, "Endorse" }, { #noLink, noLink[3].text })
        assert.are.same({}, world.openMenu("MENU_UNIT_PLAYER", { unit = "target" })) -- nothing targeted
        assert.are.same({}, world.openMenu("MENU_UNIT_PLAYER", { name = "Corvina", server = "Ashby" }))
        assert.are.same({}, world.openMenu("MENU_UNIT_PLAYER", nil))
    end)

    it("waits for combat before opening the popup, and closes it with the reason in chat when it can't endorse", function()
        boot({ frameWithout = { Raise = true } }) -- not linked, on a client whose frames can't Raise
        world.inCombat = true
        world.openMenu("MENU_UNIT_PLAYER", { unit = "party2" })[3].click()
        assert.is_nil(ns.EndorsePopup())
        world.inCombat = false
        world.fire("PLAYER_REGEN_ENABLED")
        local popup = ns.EndorsePopup()
        assert.are.equal("Endorse Sir Rocky", popup.title.text)
        popup.buttons[1].scripts.OnClick(popup.buttons[1])
        assert.truthy(world.chat[#world.chat]:find("/lfgplus setup", 1, true))
        assert.is_false(popup.shown)
        assert.are.equal(0, #world.sent)
    end)

    it("leaves out players already endorsed: no menu entry, no prompt row, and no prompt once nobody's left", function()
        boot({ saved = { setupCode = codes.valid[2].input } })
        local corvina = ns.UnitIdentity("party1")
        -- Unconfirmed: the menu still offers to replace it, but the prompt doesn't ask again.
        ns.db.endorsed[corvina.key] = { at = 1, tags = 2, proven = false }
        assert.are.equal(4, #world.openMenu("MENU_UNIT_PARTY", { unit = "party1" }))
        ns.db.endorsed[corvina.key] = { at = 1, tags = 2, proven = true }
        local confirmed = world.openMenu("MENU_UNIT_PARTY", { unit = "party1" }) -- no Endorse; the link stays
        assert.are.same({ 3, "Copy LFG+ URL" }, { #confirmed, confirmed[3].text })
        assert.are.equal(4, #world.openMenu("MENU_UNIT_PARTY", { unit = "party2" }))
        ns.ShowGroupPrompt()
        local prompt = frame("LFGPlusPromptFrame")
        assert.are.equal("Sir Rocky", prompt.rows[1].identity.name)
        assert.are.equal(1, #prompt.rows)
        prompt:Hide()
        ns.db.endorsed[ns.UnitIdentity("party2").key] = { at = 1, tags = 1 }
        ns.ShowGroupPrompt()
        assert.is_false(prompt.shown)
        assert.are.equal("You've endorsed everyone in your group.", (world.chat[#world.chat]:gsub("^.-|r ", "")))
        -- After a run, too: everyone's endorsed, so no prompt.
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.fire("LFG_COMPLETION_REWARD")
        assert.is_false(prompt.shown)
        assert.truthy(logHas("run ended (LFG_COMPLETION_REWARD)"))
    end)

    it("adds no menu entry on a client without the Menu API", function()
        boot({ without = { "Menu" } })
        assert.truthy(logHas("no Menu API on this client"))
    end)

    it("shows a toast and plays a sound when someone endorses you, and puts the record in the upload box", function()
        boot({ saved = { setupCode = codes.valid[2].input } })
        local bytes = ns.RecordFromText(records.cases[1].realText) -- Corvina Ashby endorsed Middle Foot, Skilled, BRD
        world.fire("CHAT_MSG_ADDON", "LFGPLUS", "R:" .. ns.ToBase64Url(bytes), "WHISPER", "Corvina Ashby")
        local toast = frame("LFGPlusToast")
        assert.truthy(toast.shown)
        assert.truthy(toast.text.text:find("Corvina Ashby endorsed you \194\183 Skilled", 1, true))
        assert.are.equal(1, #world.sounds)
        SlashCmdList.LFGPLUS("upload")
        local upload = frame("LFGPlusUploadFrame")
        assert.truthy(upload.shown)
        assert.are.equal(records.cases[1].realText, upload.text)
        SlashCmdList.LFGPLUS("upload") -- again: the same box
        assert.are.equal(upload, frame("LFGPlusUploadFrame"))
        -- Read-only: whatever the player types is put back.
        upload.box:SetText("typed over")
        upload.box.scripts.OnTextChanged(upload.box, false)
        assert.are.equal("typed over", upload.box.text)
        upload.box.scripts.OnTextChanged(upload.box, true)
        assert.are.equal(records.cases[1].realText, upload.box.text)
    end)

    it("splits the upload box into parts the site takes whole, and steps through them", function()
        boot({ saved = { setupCode = codes.valid[2].input } })
        ns.db.records = {}
        for i = 1, 1001 do ns.db.records[i] = { dir = "given", text = "LFGR1:r" .. i, at = 1794096000 } end
        SlashCmdList.LFGPLUS("upload")
        local upload = frame("LFGPlusUploadFrame")
        local function linesShown() local n = 0 for _ in upload.text:gmatch("[^\n]+") do n = n + 1 end return n end
        assert.are.equal("Part 1 of 3: 500 endorsements. Press Ctrl+C to copy, then paste on lfg.plus/upload.", upload.hint.text)
        assert.are.equal(500, linesShown())
        assert.truthy(upload.next.shown)
        assert.is_false(upload.done.shown) -- "I uploaded these" waits for the last part
        assert.are.equal("Next part (2 of 3)", upload.next.text)
        upload.next.scripts.OnClick(upload.next)
        assert.are.equal("Part 2 of 3: 500 endorsements. Press Ctrl+C to copy, then paste on lfg.plus/upload.", upload.hint.text)
        assert.are.equal("LFGR1:r501", upload.text:match("^[^\n]+"))
        upload.next.scripts.OnClick(upload.next)
        assert.are.equal("Part 3 of 3: 1 endorsement. Press Ctrl+C to copy, then paste on lfg.plus/upload.", upload.hint.text)
        assert.are.equal("LFGR1:r1001", upload.text)
        assert.are.equal("Back to part 1", upload.next.text)
        assert.is_true(upload.done.shown)
        upload.next.scripts.OnClick(upload.next)
        assert.are.equal(500, linesShown())
        assert.are.equal("LFGR1:r1", upload.text:match("^[^\n]+"))
        -- Fewer records than the part asked for (some were pruned meanwhile): part 1, and no button once one paste is enough.
        upload.part = 3
        for i = 2, 1001 do ns.db.records[i] = nil end
        upload.next.scripts.OnClick(upload.next)
        assert.are.equal("1 endorsement. Press Ctrl+C to copy, then paste on lfg.plus/upload.", upload.hint.text)
        assert.is_false(upload.next.shown)
        assert.truthy(ns.WaitingLine())
        world.click(upload.done)
        assert.is_false(upload.shown)
        assert.is_nil(ns.WaitingLine()) -- all uploaded
        assert.truthy(logHas("marked everything up to 0 as uploaded"))
        SlashCmdList.LFGPLUS("upload") -- and still there to paste again
        assert.is_true(upload.shown)
    end)

    it("ignores a handshake message that isn't a whisper, malformed ones and other addons' messages, without errors", function()
        boot({})
        world.fire("CHAT_MSG_ADDON", "LFGPLUS", "Q:xyz", "PARTY", "Corvina Ashby")
        world.fire("CHAT_MSG_ADDON", "LFGPLUS", "nonsense", "WHISPER", "Corvina Ashby")
        world.fire("CHAT_MSG_ADDON", "OTHER", "Q:xyz", "WHISPER", "Corvina Ashby")
        assert.truthy(logHas("ignored Q: on PARTY from Corvina Ashby (whispers only"))
        assert.truthy(logHas("malformed message"))
        assert.is_false(logHas("ignored a request")) -- the PARTY one never reached the handshake
    end)

    it("sends a finished record to the party as well, and ignores it coming back", function()
        boot({ saved = { setupCode = codes.valid[2].input, debug = true } }) -- debug: received messages are logged
        SlashCmdList.LFGPLUS("group")
        skilledButton().scripts.OnClick(skilledButton())
        world.advance(16) -- no ack: finishes unproven
        local kinds = {}
        for _, m in ipairs(world.sent) do kinds[#kinds + 1] = m.message:sub(1, 2) .. " " .. m.channel .. " " .. tostring(m.target) end
        assert.are.same({ "Q: WHISPER Corvina Ashby", "R: WHISPER Corvina Ashby", "R: PARTY nil" }, kinds)
        assert.are.equal(world.sent[2].message, world.sent[3].message)
        -- The fake client echoed the PARTY message back, as the game does: still one record, nothing carried.
        assert.truthy(logHas("received R: from Middle Foot on PARTY"))
        assert.are.equal(1, #ns.db.records)
        assert.are.equal(0, #ns.db.carried)
    end)

    it("sends a finished record to the raid in a raid, to the instance group in one, and to nobody outside a group", function()
        local function channelsAfterEndorsing(options)
            options.saved = { setupCode = codes.valid[2].input }
            boot(options)
            ns.Endorse(ns.UnitIdentity(options.raid and "raid2" or "party1") or ns.UnitIdentity("target"), 2, true)
            world.advance(16)
            local channels = {}
            for _, m in ipairs(world.sent) do channels[#channels + 1] = m.message:sub(1, 2) .. " " .. m.channel end
            return channels
        end
        local raid = {
            player = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            raid1 = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            raid2 = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" },
        }
        assert.are.same({ "Q: WHISPER", "R: WHISPER", "R: RAID" }, channelsAfterEndorsing({ raid = true, units = raid }))
        assert.are.same({ "Q: WHISPER", "R: WHISPER", "R: INSTANCE_CHAT" }, channelsAfterEndorsing({ instanceGroup = true }))
        assert.are.same({ "Q: WHISPER", "R: WHISPER", "R: INSTANCE_CHAT" },
            channelsAfterEndorsing({ instanceGroup = true, raid = true, units = raid }))
        assert.are.same({ "Q: WHISPER", "R: WHISPER" }, channelsAfterEndorsing({ units = {
            player = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            target = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" },
        } }))
    end)

    it("carries a record heard in the group between two other players, real or quiet alike, and uploads it after its own", function()
        boot({ saved = { setupCode = codes.valid[3].input }, units = {
            player = { name = "Sir", realm = "Rocky", guid = "Player-4395-00000099" },
            party1 = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" },
            party2 = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
        } })
        SlashCmdList.LFGPLUS("") -- the window is open: it redraws as copies arrive
        local overview = ns.Window().pages.overview
        assert.are.equal("Nothing waiting to upload.", overview.waiting:GetText())
        assert.is_false(overview.upload:IsEnabled())
        -- Corvina Ashby endorsed Middle Foot (test/test-vectors/record-v1.json): the same record signed with the real
        -- key and with the drop key. Nothing here can tell which is which, and both are kept.
        local case = records.cases[1]
        local function carried(text, seq)
            return { text = text, at = world.clock, account = case.request.endorserAccount, counter = case.request.counter,
                proven = case.ack.ackKeyVersion > 0, seq = seq }
        end
        world.hear("R:" .. ns.ToBase64Url(ns.RecordFromText(case.realText)), "PARTY", "party1")
        assert.are.same({ carried(case.realText, 1) }, ns.db.carried)
        assert.are.equal("Waiting to upload: 0 given, 0 received, 1 from your groups.", overview.waiting:GetText())
        assert.is_true(overview.upload:IsEnabled())
        world.hear("R:" .. ns.ToBase64Url(ns.RecordFromText(case.dropText)), "PARTY", "party1")
        assert.are.same({ carried(case.realText, 1), carried(case.dropText, 2) }, ns.db.carried)
        assert.are.equal(0, #ns.db.records)
        assert.is_nil(frame("LFGPlusToast")) -- not ours: no toast
        -- Sent by someone other than its endorser, or as a handshake message on the group channel: not carried.
        world.hear("R:" .. ns.ToBase64Url(ns.RecordFromText(records.cases[2].realText)), "PARTY", "party2")
        assert.are.equal(2, #ns.db.carried)
        -- The Endorsements tab lists only our own, but its upload button works for carried copies too.
        world.click(ns.Window().tabs.endorsements)
        assert.is_true(ns.Window().pages.endorsements.upload:IsEnabled())
        ns.db.records = { { dir = "given", text = "LFGR1:mine", at = world.clock, name = "Corvina Ashby", tags = 1 } }
        SlashCmdList.LFGPLUS("upload")
        assert.are.equal("LFGR1:mine\n" .. case.realText .. "\n" .. case.dropText, frame("LFGPlusUploadFrame").text)
        SlashCmdList.LFGPLUS("records")
        assert.truthy(world.chat[#world.chat]:find("1 endorsement given, 0 received and 2 from your groups are waiting to be uploaded.", 1, true))
        assert.are.equal("Waiting to upload: 1 given, 0 received, 2 from your groups.", ns.LauncherTooltipLines()[3])
        -- Thirty-six days on, the next login drops them with our own.
        world.clock = world.clock + 36 * 86400
        world.fire("PLAYER_LOGIN")
        assert.are.same({}, ns.db.carried)
        assert.are.same({}, ns.db.records)
    end)

    it("answers /lfgplus log, debug, diag and records", function()
        boot({})
        SlashCmdList.LFGPLUS("log 5")
        assert.truthy(world.chat[#world.chat]:find("[", 1, true))
        SlashCmdList.LFGPLUS("debug")
        assert.are.equal(true, ns.db.debug)
        SlashCmdList.LFGPLUS("diag")
        assert.truthy(world.chat[#world.chat]:find("Player-4395-00000007", 1, true))
        SlashCmdList.LFGPLUS("records")
        assert.are.equal("0 endorsements given, 0 received and 0 from your groups are waiting to be uploaded.",
            (world.chat[#world.chat]:gsub("^.-|r ", "")))
        SlashCmdList.LFGPLUS("log clear")
        assert.truthy(world.chat[#world.chat]:find("Log cleared.", 1, true))
        assert.are.equal(0, #LFGPlusLog.entries)
    end)

    it("keeps one run per instance, counts only boss kills, and ends it on entering another instance after a kill", function()
        boot({})
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        local run = ns.run
        world.fire("ZONE_CHANGED_NEW_AREA") -- still in Blackrock Depths
        assert.are.equal(run, ns.run)
        world.fire("ENCOUNTER_END", 227, "High Interrogator Gerstahn", 1, 5, 0) -- a wipe
        assert.are.equal(0, run.kills)
        world.fire("ENCOUNTER_END", 227, "High Interrogator Gerstahn", 1, 5, 1)
        assert.are.equal(1, run.kills)
        world.instance = { name = "Stratholme", type = "party", id = 329 }
        world.fire("PLAYER_ENTERING_WORLD")
        assert.truthy(logHas("run ended (entered another instance)"))
        assert.truthy(frame("LFGPlusPromptFrame").shown)
        assert.are.equal("Stratholme", ns.run.name)
    end)

    it("doesn't prompt after a solo run, or twice for one run", function()
        boot({ units = { player = { name = "Middle", realm = "Foot" } } })
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.fire("LFG_COMPLETION_REWARD")
        assert.truthy(logHas("0 players"))
        world.fire("SCENARIO_COMPLETED") -- already over
        world.instance = nil
        world.fire("ZONE_CHANGED_NEW_AREA")
        assert.is_nil(ns.run)
        world.fire("CHALLENGE_MODE_COMPLETED") -- no run at all
        assert.is_nil(frame("LFGPlusPromptFrame"))
    end)

    it("offers players who joined during the run", function()
        boot({ units = { player = { name = "Middle", realm = "Foot" } } })
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.units.party1 = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" }
        world.fire("GROUP_ROSTER_UPDATE")
        world.fire("LFG_COMPLETION_REWARD")
        local prompt = frame("LFGPlusPromptFrame")
        assert.truthy(prompt.shown)
        assert.are.equal("Corvina Ashby", prompt.rows[1].name.text)
    end)

    it("lists a raid's members, and logs each member's client facts once", function()
        boot({ raid = true, units = {
            player = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            raid1 = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            raid2 = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" },
            raid3 = { name = "Sir", realm = "Rocky", guid = "Player-4395-00000099" },
        } })
        world.instance = { name = "Molten Core", type = "raid", id = 409 }
        world.fire("PLAYER_ENTERING_WORLD")
        assert.are.equal(2, #ns.run.order) -- everyone but us
        world.fire("GROUP_ROSTER_UPDATE")
        world.fire("GROUP_ROSTER_UPDATE")
        local count = 0
        for _, e in ipairs(LFGPlusLog.entries) do if e.m:find("member raid2:", 1, true) then count = count + 1 end end
        assert.are.equal(1, count)
    end)

    it("records an API that errors, and takes a snapshot even before the log exists", function()
        boot({})
        _G.GetRealmID = function() error("not on this client") end
        assert.truthy(ns.CollectDiagnostics().realmId:find("<error: ", 1, true))
        local log = LFGPlusLog
        _G.LFGPlusLog = nil
        assert.has_no.errors(function() ns.CollectDiagnostics() end)
        _G.LFGPlusLog = log
        _G.GetRealmID = nil
    end)

    it("logs the client's notices about whisper targets and the logout, and ignores events it has no handler for", function()
        boot({})
        world.fire("CHAT_MSG_SYSTEM", "No player named \"Nobody Here\" is currently playing.")
        world.fire("CHAT_MSG_SYSTEM", "You are now Away.")
        assert.truthy(logHas("system: No player named"))
        assert.is_false(logHas("You are now Away"))
        world.fire("PLAYER_LOGOUT")
        assert.truthy(logHas("logging out: 0 records held, 0 messages still queued"))
        local events
        for _, f in ipairs(world.frames) do if f.events.CHAT_MSG_ADDON then events = f end end
        assert.has_no.errors(function() events.onEvent(events, "SOME_NEW_EVENT") end)
    end)

    it("skips quietly any event this client doesn't have", function()
        boot({ missingEvents = { CHALLENGE_MODE_COMPLETED = true } })
        assert.truthy(logHas("event CHALLENGE_MODE_COMPLETED isn't available on this client"))
    end)

    it("sends through an older client's global addon-message API, and logs it when the client has none", function()
        boot({ addonMessageApi = "global", saved = { setupCode = codes.valid[2].input } })
        SlashCmdList.LFGPLUS("group")
        skilledButton().scripts.OnClick(skilledButton())
        assert.are.equal("WHISPER", world.sent[1].channel)
        assert.are.equal("Corvina Ashby", world.sent[1].target)
        boot({ addonMessageApi = "none", saved = { setupCode = codes.valid[2].input } })
        SlashCmdList.LFGPLUS("group")
        skilledButton().scripts.OnClick(skilledButton())
        assert.are.equal(0, #world.sent)
        assert.truthy(logHas("result no-api"))
    end)

    it("says why when a prompt button can't endorse, and reuses the prompt", function()
        boot({})
        SlashCmdList.LFGPLUS("group")
        local prompt = frame("LFGPlusPromptFrame")
        skilledButton().scripts.OnClick(skilledButton())
        assert.truthy(world.chat[#world.chat]:find("Link your LFG+ account first", 1, true))
        SlashCmdList.LFGPLUS("group")
        local count = 0
        for _, f in ipairs(world.frames) do if f.name == "LFGPlusPromptFrame" then count = count + 1 end end
        assert.are.equal(1, count)
        assert.truthy(prompt.shown)
    end)

    it("endorses the target with /endorse, and says who to target when there's no one", function()
        boot({ saved = { setupCode = codes.valid[2].input }, units = {
            player = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" },
            target = { name = "Corvina", realm = "Ashby", guid = "Player-4395-0A1B2C3D" },
        } })
        assert.are.same({ 2, true }, { ns.ParseEndorseArgs("Skilled quiet nonsense") })
        assert.are.same({ 8, false }, { ns.ParseEndorseArgs("lead") })
        assert.is_nil((ns.ParseEndorseArgs("quiet")))
        SlashCmdList.LFGPLUSENDORSE("quiet") -- no tag: there is no untagged endorsement
        assert.truthy(world.chat[#world.chat]:find("Pick what they did best", 1, true))
        assert.are.equal(0, #world.sent)
        SlashCmdList.LFGPLUSENDORSE("skilled quiet")
        assert.are.equal("Q:", world.sent[1].message:sub(1, 2))
        world.advance(16) -- no ack: finishes unproven
        assert.truthy(world.chat[#world.chat]:find("You endorsed Corvina Ashby \194\183 Skilled.", 1, true))
        world.units.target = nil
        SlashCmdList.LFGPLUSENDORSE("")
        assert.truthy(world.chat[#world.chat]:find("Target another player", 1, true))
    end)

    it("names the place in a toast when it can, and shows toasts one after another", function()
        boot({})
        assert.are.equal("Map 1429", ns.PlaceName(2, 1429))
        assert.are.equal("Instance 230", ns.PlaceName(1, 230))
        assert.is_nil(ns.PlaceName(0, 0))
        _G.GetRealZoneText = function() return "" end
        assert.is_nil(ns.PlaceName(1, 230))
        local plain = { endorser = { name = "Sir Rocky" }, tags = 1, locationKind = 0, locationId = 0 }
        assert.are.equal("Sir Rocky endorsed you \194\183 Fun", ns.EndorsedToastText(plain))

        ns.db.toastSound = false
        ns.ShowEndorsedToast(plain)
        ns.ShowEndorsedToast({ endorser = { name = "Corvina Ashby" }, tags = 2, locationKind = 2, locationId = 1429 })
        local toast = frame("LFGPlusToast")
        assert.truthy(toast.text.text:find("Sir Rocky endorsed you", 1, true))
        assert.are.equal(0, #world.sounds)
        ns.db.toastSound = true
        _G.SOUNDKIT = nil -- a client without the sound kit table: no sound, and no error
        world.advance(5)
        assert.truthy(toast.shown)
        assert.truthy(toast.text.text:find("Corvina Ashby endorsed you \194\183 Skilled \194\183 Map 1429", 1, true))
        assert.are.equal(0, #world.sounds)
        world.advance(5)
        assert.is_false(toast.shown)
    end)

    it("asks first when set to, and acks once the player accepts", function()
        boot({ saved = { setupCode = codes.valid[2].input, ack = { group = "ask" } } })
        local bytes = assert(ns.EncodeRequest({
            gameVersion = 40, region = 1, keyVersion = 1, endorserAccount = string.rep("0", 31) .. "1", counter = 77,
            endorsedAt = world.clock, locationKind = 1, locationId = 230,
            endorser = { name = "Corvina Ashby", realm = "", guid = "Player-4395-0A1B2C3D" },
            endorsee = { name = "Middle Foot", realm = "", guid = "Player-4395-00000007" },
        }))
        world.fire("CHAT_MSG_ADDON", "LFGPLUS", "Q:" .. ns.ToBase64Url(bytes), "WHISPER", "Corvina Ashby")
        assert.are.equal("LFGPLUS_ACK", world.popups[#world.popups])
        local shown = world.popupArgs[#world.popupArgs]
        assert.are.equal("Corvina Ashby", shown.a)
        assert.are.equal(0, #world.sent)
        StaticPopupDialogs.LFGPLUS_ACK.OnCancel(nil, nil) -- closed with no request attached: nothing to log
        StaticPopupDialogs.LFGPLUS_ACK.OnCancel(nil, shown.data)
        assert.truthy(logHas("ignored request 77 from Corvina Ashby"))
        StaticPopupDialogs.LFGPLUS_ACK.OnAccept(nil, shown.data)
        assert.are.equal("A:", world.sent[1].message:sub(1, 2))
        assert.are.equal("Corvina Ashby", world.sent[1].target)
    end)

    -- ─── When a run ends ─────────────────────────────────────────────────────

    --- Boots inside Blackrock Depths with one boss down.
    local function killedOne(options)
        boot(options or {})
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.fire("ENCOUNTER_START", 227, "High Interrogator Gerstahn")
        world.fire("ENCOUNTER_END", 227, "High Interrogator Gerstahn", 1, 5, 1)
        assert.are.equal(1, ns.run.kills)
    end

    local function leave()
        world.instance = nil
        world.fire("ZONE_CHANGED_NEW_AREA")
    end

    local function prompted()
        local prompt = frame("LFGPlusPromptFrame")
        return prompt ~= nil and prompt.shown
    end

    it("keeps the run going while a dead player runs back, and ends it only once they're alive and still outside", function()
        killedOne()
        world.dead = true -- released to the graveyard
        leave()
        assert.truthy(logHas("left Blackrock Depths (dead: true)"))
        world.advance(600)
        assert.is_false(prompted())
        assert.truthy(logHas("still outside Blackrock Depths, dead; looking again in 60s"))
        world.advance(60)
        assert.is_false(prompted())
        world.dead = false -- resurrected at the graveyard, and gone off elsewhere
        world.advance(60)
        assert.is_true(prompted())
        assert.truthy(logHas("run ended (10 minutes outside)"))
    end)

    it("goes on when the player comes back in, whatever the old wait would have said", function()
        killedOne()
        local run = ns.run
        world.dead = true
        leave()
        world.advance(300)
        world.dead = false
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD") -- back in as a ghost, revived at the stone
        assert.are.equal(run, ns.run)
        assert.truthy(logHas("back in Blackrock Depths: the run goes on"))
        world.advance(600)
        assert.is_false(prompted())
        world.fire("ENCOUNTER_END", 228, "Lord Roccor", 1, 5, 1)
        assert.are.equal(2, run.kills)
        -- Out again, alive: a new ten minutes from now.
        leave()
        world.advance(599)
        assert.is_false(prompted())
        world.advance(1)
        assert.is_true(prompted())
        assert.truthy(logHas("run ended (10 minutes outside): Blackrock Depths, 2 boss kills"))
    end)

    it("ends the run at once when the group is gone while outside, or when leaving after the group broke up", function()
        killedOne()
        leave()
        assert.is_false(prompted())
        world.units.party1, world.units.party2 = nil, nil -- the group disbands
        world.fire("GROUP_ROSTER_UPDATE")
        assert.is_true(prompted())
        assert.truthy(logHas("run ended (left the group)"))
        assert.is_nil(ns.run)
        -- Already out of the group inside (an LFG group done, the player leaves it and is ported out).
        killedOne()
        world.units.party1, world.units.party2 = nil, nil
        world.fire("GROUP_ROSTER_UPDATE")
        assert.is_table(ns.run) -- still inside: not over yet
        leave()
        assert.truthy(logHas("run ended (left the instance and the group)"))
        assert.is_nil(ns.run)
        -- A dead player out of the group still has the wait.
        killedOne({ units = { player = { name = "Middle", realm = "Foot" } } })
        world.dead = true
        leave()
        assert.is_table(ns.run)
    end)

    it("ends a run left behind when entering another instance, and ignores the old wait afterwards", function()
        killedOne()
        leave()
        world.instance = { name = "Stratholme", type = "party", id = 329 }
        world.fire("PLAYER_ENTERING_WORLD")
        assert.truthy(logHas("run ended (entered another instance): Blackrock Depths"))
        frame("LFGPlusPromptFrame"):Hide()
        world.advance(700)
        assert.is_false(prompted())
        assert.are.equal("Stratholme", ns.run.name)
    end)

    it("keeps the run's kills and players over a /reload in the same instance", function()
        killedOne()
        world.fire("PLAYER_LOGOUT")
        local saved = LFGPlusDB
        assert.are.equal(1, saved.run.kills)
        assert.are.equal(world.clock, saved.run.savedAt)
        -- The reload: the same saved variables, the same instance, in the same minute.
        boot({ saved = saved, instance = BRD })
        assert.are.equal(1, ns.run.kills)
        assert.are.same({ "corvina ashby", "sir rocky" }, ns.run.order)
        assert.is_nil(ns.db.run)
        assert.truthy(logHas("picked up the run in Blackrock Depths again: 1 boss kills, 2 players"))
        world.fire("PLAYER_ENTERING_WORLD")
        leave()
        world.advance(600)
        assert.is_true(prompted())
    end)

    it("doesn't pick up a saved run elsewhere, too long after, in an instance that isn't a run, or a damaged one", function()
        local function saved(changes)
            local run = { instanceId = 230, name = "Blackrock Depths", kind = "party", started = 1794096000 - 600, kills = 1,
                members = {}, order = {}, savedAt = 1794096000 - 60 }
            for k, v in pairs(changes or {}) do run[k] = v end
            return { run = run }
        end
        for _, case in ipairs({
            { saved = saved(), instance = nil, said = true },
            { saved = saved({ savedAt = 1794096000 - 1801 }), instance = BRD, said = true },
            { saved = saved(), instance = { name = "Blackrock Depths", type = "pvp", id = 230 }, said = true },
            { saved = saved({ kills = "1" }), instance = BRD },
            { saved = { run = "nonsense" }, instance = BRD },
        }) do
            boot({ saved = case.saved, instance = case.instance })
            assert.are.equal(0, ns.run and ns.run.kills or 0)
            assert.is_nil(ns.db.run)
            assert.are.equal(case.said or false, logHas("the run saved in Blackrock Depths isn't picked up"))
        end
        -- Nothing unfinished to save: the saved run is cleared.
        boot({ saved = saved() })
        world.fire("PLAYER_LOGOUT")
        assert.is_nil(LFGPlusDB.run)
        world.instance = BRD
        world.fire("PLAYER_ENTERING_WORLD")
        world.fire("LFG_COMPLETION_REWARD")
        world.fire("PLAYER_LOGOUT")
        assert.is_nil(LFGPlusDB.run)
    end)

    it("stops waiting for an encounter after a loading screen, unless the client says one is still on", function()
        boot({ saved = { setupCode = codes.valid[2].input } })
        SlashCmdList.LFGPLUS("group")
        world.fire("ENCOUNTER_START", 227, "High Interrogator Gerstahn")
        skilledButton().scripts.OnClick(skilledButton())
        assert.are.equal(0, #world.sent) -- held for the encounter
        world.fire("PLAYER_ENTERING_WORLD") -- ENCOUNTER_END never came
        assert.truthy(logHas("no encounter in progress after a loading screen"))
        assert.are.equal("Q:", world.sent[1].message:sub(1, 2))
        world.fire("PLAYER_ENTERING_WORLD")
        boot({ encounterApi = true, saved = { setupCode = codes.valid[2].input } })
        world.encounter = true
        world.fire("ENCOUNTER_START", 227, "High Interrogator Gerstahn")
        world.fire("PLAYER_ENTERING_WORLD")
        assert.is_true(ns.commState.inEncounter)
        world.encounter = false
        world.fire("PLAYER_ENTERING_WORLD")
        assert.is_false(ns.commState.inEncounter)
    end)

    it("lists a whole raid in the prompt, scrolling, and reuses its rows for a smaller group", function()
        local units = { player = { name = "Middle", realm = "Foot", guid = "Player-4395-00000007" } }
        for i = 1, 39 do units["raid" .. i] = { name = "Member", realm = "No" .. i } end
        boot({ raid = true, units = units })
        ns.ShowGroupPrompt()
        local prompt = frame("LFGPlusPromptFrame")
        assert.are.equal(39, #prompt.rows)
        assert.are.equal(39 * 26, prompt.list:GetHeight())
        local shown = 0
        for _, row in ipairs(prompt.rows) do if row.shown then shown = shown + 1 end end
        assert.are.equal(39, shown)
        ns.ShowPrompt({ ns.UnitIdentity("raid1") }, "Molten Core")
        assert.are.equal(39, #prompt.rows)
        assert.is_true(prompt.rows[1].shown)
        assert.is_false(prompt.rows[2].shown)
        assert.are.equal(26, prompt.list:GetHeight())
        ns.ShowPrompt({}, nil)
        assert.are.equal(26, prompt.list:GetHeight())
    end)

    it("works out run ends on a client without C_Timer: no wait, so a run ends on the next zone change or group change", function()
        killedOne({ without = { "C_Timer" } })
        leave()
        assert.is_false(prompted())
        world.units.party1, world.units.party2 = nil, nil
        world.fire("GROUP_ROSTER_UPDATE")
        assert.is_true(prompted())
    end)
end)

describe("runs without the UI loaded", function()
    it("end without a prompt, and a client without IsInInstance counts as outside", function()
        stubs.install({ interface = 16001, instance = BRD, units = {
            player = { name = "Middle", realm = "Foot" }, party1 = { name = "Corvina", realm = "Ashby" } } })
        local ns = loader.load({ "Core.lua", "Log.lua", "Crypto.lua", "SetupCode.lua", "Settings.lua", "Identity.lua",
            "Record.lua", "Comm.lua", "Endorse.lua", "Runs.lua" })
        ns.db = ns.ApplyDefaults({}, ns.DEFAULTS)
        ns.gameVersion = ns.GameVersions.FOREVER
        ns.UpdateRunForZone()
        assert.are.equal(1, #ns.run.order)
        ns.CompleteRun("test")
        assert.truthy(ns.run.completed)
        _G.IsInInstance = nil
        ns.UpdateRunForZone()
        assert.is_nil(ns.run)
        -- A saved run isn't picked up where the client can't say we're in its instance.
        ns.db.run = { instanceId = 230, name = "Blackrock Depths", started = 1, kills = 1, members = {}, order = {}, savedAt = GetServerTime() }
        ns.RestoreRun()
        assert.is_nil(ns.run)
        assert.is_nil(ns.db.run)
    end)
end)
