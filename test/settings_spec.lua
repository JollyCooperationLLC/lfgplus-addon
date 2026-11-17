-- /lfgplus settings, driven through the whole addon in a fake client. The setup codes come from
-- test/test-vectors/setup-code.json, and the keys they must produce from key-derivation.json.
local stubs = require("test.helpers.wow_stubs")
local loader = require("test.helpers.load_addon")

local codes = loader.read_vectors("setup-code.json")
local keyVectors = loader.read_vectors("key-derivation.json")
local VALID = codes.valid[1].input           -- account ...0001, key version 1
local EXPECTED_KEYS = keyVectors.cases[1]   -- the same account and version

describe("/lfgplus settings", function()
    local function boot(savedVariables)
        _G.LFGPlusDB = savedVariables
        local world = stubs.install({ units = { player = { name = "Kaelwyn", realm = "Whitemane" } } })
        local ns = world.loadAddon()
        world.fireAddonLoaded()
        return world, ns
    end

    --- Pastes text into the setup dialog and presses Accept. Returns true when the dialog stays open (WoW hides a popup
    -- unless its OnAccept returns true).
    local function paste(world, text)
        SlashCmdList.LFGPLUS("setup")
        assert.are.equal("LFGPLUS_SETUP", world.popups[#world.popups])
        local box = { GetText = function() return text end }
        return StaticPopupDialogs.LFGPLUS_SETUP.OnAccept({ editBox = box })
    end

    local function chatContains(world, needle)
        for _, line in ipairs(world.chat) do
            if line:find(needle, 1, true) then return true end
        end
        return false
    end

    after_each(function() _G.LFGPlusDB = nil end)

    it("starts unlinked, with prompts, sound and automatic acks on", function()
        local _, ns = boot()
        assert.is_false(ns.IsLinked())
        assert.are.equal(true, LFGPlusDB.promptAfterRuns)
        assert.are.equal(true, LFGPlusDB.toastSound)
        for _, category in ipairs(ns.ACK_CATEGORIES) do assert.are.equal("auto", ns.AckModeFor(category)) end
    end)

    it("links with a pasted setup code and derives the same keys as the server", function()
        local world, ns = boot()
        paste(world, "  " .. VALID .. "\n")
        assert.truthy(ns.IsLinked())
        assert.are.equal(EXPECTED_KEYS.accountId, ns.account.accountId)
        assert.are.equal(1, ns.account.keyVersion)
        assert.are.equal(EXPECTED_KEYS.realKeyHex, ns.ToHex(ns.keys.real))
        assert.are.equal(EXPECTED_KEYS.dropKeyHex, ns.ToHex(ns.keys.drop))
        assert.are.equal(EXPECTED_KEYS.ackKeyHex, ns.ToHex(ns.keys.ack))
        assert.are.equal(VALID, LFGPlusDB.setupCode) -- saved trimmed
        assert.truthy(chatContains(world, "Linked to your LFG+ account"))
    end)

    it("never prints the setup code or any key", function()
        local world, ns = boot()
        paste(world, VALID)
        SlashCmdList.LFGPLUS("help")
        local body = VALID:sub(6)
        for _, line in ipairs(world.chat) do
            assert.is_nil(line:find(body, 1, true))
            assert.is_nil(line:find(EXPECTED_KEYS.realKeyHex, 1, true))
            assert.is_nil(line:find(EXPECTED_KEYS.accountSecretHex, 1, true))
        end
        assert.truthy(ns.IsLinked())
    end)

    it("refuses a bad paste, keeps the current link and says what to do", function()
        local world, ns = boot()
        assert.is_false(paste(world, VALID)) -- a good code closes the dialog
        assert.is_true(paste(world, codes.invalid[7].input)) -- checksum mismatch: the dialog stays up to be corrected
        assert.truthy(ns.IsLinked())
        assert.are.equal(VALID, LFGPlusDB.setupCode)
        assert.truthy(world.chat[#world.chat]:find("doesn't look like a setup code", 1, true))
    end)

    it("empties and focuses the setup box when the dialog opens, and links on Enter", function()
        local _, ns = boot()
        local dialogs = StaticPopupDialogs.LFGPLUS_SETUP
        local box = { text = "left over" }
        function box:SetText(text) self.text = text end
        function box:SetFocus() self.focused = true end
        dialogs.OnShow({ editBox = box })
        assert.are.equal("", box.text)
        assert.is_true(box.focused)
        assert.has_no.errors(function() dialogs.OnShow({}) end) -- a dialog without an edit box
        local dialog = {}
        function dialog:Hide() self.hidden = true end
        local enter = { GetText = function() return VALID end, GetParent = function() return dialog end }
        dialog.editBox = enter
        local bad = { GetText = function() return codes.invalid[7].input end, GetParent = function() return dialog end }
        dialog.editBox = bad
        dialogs.EditBoxOnEnterPressed(bad)
        assert.is_nil(dialog.hidden) -- a bad code keeps the dialog open
        dialog.editBox = enter
        dialogs.EditBoxOnEnterPressed(enter)
        assert.truthy(ns.IsLinked())
        assert.is_true(dialog.hidden)
    end)

    it("restores the link at the next login without asking again", function()
        local _, ns = boot({ setupCode = VALID })
        assert.truthy(ns.IsLinked())
        assert.are.equal(EXPECTED_KEYS.realKeyHex, ns.ToHex(ns.keys.real))
    end)

    it("drops a saved code that no longer parses, with a notice", function()
        local world, ns = boot({ setupCode = VALID:sub(1, -2) })
        assert.is_false(ns.IsLinked())
        assert.is_nil(LFGPlusDB.setupCode)
        assert.truthy(chatContains(world, "isn't valid any more"))
    end)

    it("unlinks", function()
        local _, ns = boot({ setupCode = VALID })
        SlashCmdList.LFGPLUS("unlink")
        assert.is_false(ns.IsLinked())
        assert.is_nil(LFGPlusDB.setupCode)
        assert.is_nil(ns.keys)
    end)

    it("resets everything only once confirmed: /lfgplus reset asks, Delete empties the saved data and reloads", function()
        local world, ns = boot({ setupCode = VALID, promptAfterRuns = false, records = { { dir = "given", text = "x" } } })
        SlashCmdList.LFGPLUS("reset")
        assert.are.equal("LFGPLUS_RESET", world.popups[#world.popups])
        assert.are.equal(VALID, LFGPlusDB.setupCode) -- nothing happens until the player presses Delete
        assert.are.equal(0, world.reloads)
        StaticPopupDialogs.LFGPLUS_RESET.OnAccept()
        assert.are.same({}, LFGPlusDB)
        assert.are.equal(ns.db, LFGPlusDB) -- emptied in place: the client saves this table on reload
        assert.are.equal(1, world.reloads)
        assert.truthy(LFGPlusLog.entries[#LFGPlusLog.entries].m:find("reset: every record and setting deleted", 1, true))
        -- After the reload the addon starts from the defaults, unlinked.
        local _, fresh = boot(LFGPlusDB)
        assert.is_false(fresh.IsLinked())
        assert.are.equal(true, LFGPlusDB.promptAfterRuns)
        assert.are.same({}, LFGPlusDB.records)
    end)

    it("toggles the post-run prompt and the sound", function()
        local world = boot()
        SlashCmdList.LFGPLUS("prompt")
        assert.are.equal(false, LFGPlusDB.promptAfterRuns)
        assert.truthy(world.chat[#world.chat]:find("off", 1, true))
        SlashCmdList.LFGPLUS("PROMPT")
        assert.are.equal(true, LFGPlusDB.promptAfterRuns)
        SlashCmdList.LFGPLUS("sound")
        assert.are.equal(false, LFGPlusDB.toastSound)
    end)

    it("sets each ack category to auto or ask, and refuses anything else", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("ack guild ask")
        assert.are.equal("ask", ns.AckModeFor("guild"))
        assert.are.equal("auto", ns.AckModeFor("group"))
        SlashCmdList.LFGPLUS("ack others ASK")
        assert.are.equal("ask", ns.AckModeFor("others"))
        SlashCmdList.LFGPLUS("ack guild auto")
        assert.are.equal("auto", ns.AckModeFor("guild"))
        SlashCmdList.LFGPLUS("ack raid never")
        assert.truthy(world.chat[#world.chat]:find("Usage", 1, true))
        assert.is_nil(LFGPlusDB.ack.raid)
    end)

    it("shows the link state and every setting in /lfgplus", function()
        local world = boot({ setupCode = VALID, ack = { group = "auto", guild = "ask", friends = "auto", others = "auto" } })
        SlashCmdList.LFGPLUS("help")
        assert.truthy(chatContains(world, "Account: linked."))
        assert.truthy(chatContains(world, "Guild ask first"))
        assert.truthy(chatContains(world, "/lfgplus setup"))
    end)
end)
