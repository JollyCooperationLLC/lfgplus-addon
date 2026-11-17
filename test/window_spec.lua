-- The minimap button (embedded LibDataBroker + LibDBIcon), the LFG+ window and the Options → AddOns page, driven
-- through the whole addon in the fake client. The specs can check wiring and behaviour, not how anything looks.
local stubs = require("test.helpers.wow_stubs")
local loader = require("test.helpers.load_addon")

local VALID_CODE = loader.read_vectors("setup-code.json").valid[1].input
local records = loader.read_vectors("record-v1.json")

describe("the minimap button and the LFG+ window", function()
    local function boot(options, savedVariables)
        _G.LFGPlusDB = savedVariables
        options = options or {}
        options.interface = options.interface or 16001
        options.units = options.units or { player = { name = "Middle", realm = "Foot" } }
        local world = stubs.install(options)
        local ns = world.loadAddon()
        world.fireAddonLoaded()
        world.fire("PLAYER_LOGIN")
        return world, ns
    end

    local function icon() return LibStub("LibDBIcon-1.0") end

    after_each(function() _G.LFGPlusDB = nil end)

    it("loads the embedded libraries and registers a launcher with the LFG+ icon", function()
        local _, ns = boot()
        assert.is_table(LibStub("LibDataBroker-1.1"))
        assert.is_true(icon():IsRegistered("LFGPlus"))
        local launcher = LibStub("LibDataBroker-1.1"):GetDataObjectByName("LFGPlus")
        assert.are.equal("launcher", launcher.type)
        assert.are.equal("Interface\\AddOns\\LFGPlus\\Media\\Icon", launcher.icon)
        -- LibDBIcon keeps its position and visibility in our saved variables.
        assert.are.equal(LFGPlusDB.minimap, icon():GetMinimapButton("LFGPlus").db)
        assert.is_true(ns.IsMinimapShown())
    end)

    it("ships the icon file the TOC and the launcher point at", function()
        local handle = assert(io.open("LFGPlus/Media/Icon.tga", "rb"))
        local header = handle:read(18)
        handle:close()
        assert.are.equal(2, header:byte(3))                       -- uncompressed true colour
        assert.are.equal(64, header:byte(13) + header:byte(14) * 256) -- power-of-two width
        assert.are.equal(32, header:byte(17))                     -- with alpha
        local toc = assert(io.open("LFGPlus/LFGPlus.toc")):read("*a")
        assert.truthy(toc:find("## IconTexture: Interface\\AddOns\\LFGPlus\\Media\\Icon", 1, true))
    end)

    it("opens the window on a left-click and its settings on a right-click, and closes it again", function()
        local _, ns = boot()
        local launcher = LibStub("LibDataBroker-1.1"):GetDataObjectByName("LFGPlus")
        launcher.OnClick(nil, "LeftButton")
        local window = ns.Window()
        assert.is_true(window:IsShown())
        assert.are.equal("overview", window.current)
        launcher.OnClick(nil, "RightButton")
        assert.are.equal("settings", window.current)
        assert.is_true(window.pages.settings.page:IsShown())
        assert.is_false(window.pages.overview.page:IsShown())
        launcher.OnClick(nil, "LeftButton")
        assert.is_false(window:IsShown())
    end)

    it("shows link status, data and waiting records in the button's tooltip", function()
        local _, ns = boot()
        local tooltip = { lines = {} }
        function tooltip:AddLine(text) table.insert(self.lines, text) end
        LibStub("LibDataBroker-1.1"):GetDataObjectByName("LFGPlus").OnTooltipShow(tooltip)
        assert.are.same({ "LFG+", "Account not linked.", "Data: 8 players, from 2026-11-07.",
            "Click to open. Right-click for settings." }, tooltip.lines)
        ns.db.records = { { dir = "given", text = "x", at = 1794096000, name = "Sir Rocky" } }
        assert.are.equal("Waiting to upload: 1 given, 0 received.", ns.LauncherTooltipLines()[3])
    end)

    it("opens with plain /lfgplus, keeps the command list on /lfgplus help, and hides the button on /lfgplus minimap", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("")
        assert.is_true(ns.Window():IsShown())
        SlashCmdList.LFGPLUS("help")
        assert.truthy(world.chat[#world.chat]:find("/endorse", 1, true))
        SlashCmdList.LFGPLUS("minimap")
        assert.is_true(LFGPlusDB.minimap.hide)
        assert.is_false(icon():GetMinimapButton("LFGPlus"):IsShown())
        SlashCmdList.LFGPLUS("minimap")
        assert.is_false(LFGPlusDB.minimap.hide)
        assert.is_true(icon():GetMinimapButton("LFGPlus"):IsShown())
    end)

    it("changes settings from the Settings tab", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("settings")
        local s = ns.Window().pages.settings
        assert.is_true(s.prompt:GetChecked())
        world.toggle(s.prompt)
        assert.is_false(LFGPlusDB.promptAfterRuns)
        world.toggle(s.sound)
        assert.is_false(LFGPlusDB.toastSound)
        world.toggle(s.minimap)
        assert.is_true(LFGPlusDB.minimap.hide)
        world.toggle(s.ack.guild)
        assert.are.equal("ask", ns.AckModeFor("guild"))
        assert.are.equal("auto", ns.AckModeFor("group"))
        -- A slash command changes the same setting; the open tab shows it.
        SlashCmdList.LFGPLUS("prompt")
        assert.is_true(s.prompt:GetChecked())
    end)

    it("marks only the open tab selected, and lays out the Overview's actions without gaps", function()
        local _, ns = boot()
        SlashCmdList.LFGPLUS("")
        local window = ns.Window()
        assert.is_true(window.tabs.overview.selected)
        assert.is_false(window.tabs.overview:IsEnabled())
        assert.is_false(window.tabs.log.selected)
        local overview = window.pages.overview
        -- Unlinked: "Paste setup code" leads the row; nothing to upload yet.
        assert.is_true(overview.link:IsShown())
        assert.are.equal(overview.link, overview.group.point[2])
        assert.is_false(overview.upload:IsEnabled())
        -- Linked, with a record: the row starts where the hidden button was, and upload is on.
        assert(ns.LinkAccount(VALID_CODE))
        ns.db.records = { { dir = "given", text = "LFGR1:x", at = 1794096000, name = "Sir Rocky", tags = 1 } }
        ns.RefreshWindow()
        assert.is_false(overview.link:IsShown())
        assert.are.same({ "TOPLEFT", overview.waiting, "BOTTOMLEFT", 0, -20 }, overview.group.point)
        assert.is_true(overview.upload:IsEnabled())
        -- Unlink takes the left edge of its row, not the hidden "Paste setup code" button's right.
        local s = window.pages.settings
        assert.are.same(s.link.point, s.unlink.point)
    end)

    it("links and unlinks from the Settings tab", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("settings")
        local s = ns.Window().pages.settings
        assert.is_true(s.link:IsShown())
        world.click(s.link)
        assert.are.equal("LFGPLUS_SETUP", world.popups[#world.popups])
        StaticPopupDialogs.LFGPLUS_SETUP.OnAccept({ editBox = { GetText = function() return VALID_CODE end } })
        assert.is_true(ns.IsLinked())
        assert.is_true(s.unlink:IsShown())
        assert.is_false(s.link:IsShown())
        assert.truthy(s.account:GetText():find("Linked", 1, true))
        world.click(s.unlink)
        assert.is_false(ns.IsLinked())
        assert.is_true(s.link:IsShown())
    end)

    it("lists endorsements newest first and hands them to the upload box", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("")
        world.click(ns.Window().tabs.endorsements)
        local page = ns.Window().pages.endorsements
        assert.is_false(page.upload:IsEnabled())
        assert.truthy(page.summary:GetText():find("No endorsements yet", 1, true))

        ns.db.records = {
            { dir = "received", text = records.cases[1].realText, at = 1794096000, name = "Corvina Ashby", tags = 2 },
            { dir = "given", text = "LFGR1:second", at = 1794182400, name = "Sir Rocky" }, -- saved before tags were a bit field: no tag shown
        }
        ns.RefreshWindow()
        assert.is_true(page.upload:IsEnabled())
        assert.are.equal("2 endorsements held, newest first.", page.summary:GetText())
        assert.are.equal("09 Nov  You endorsed Sir Rocky\n08 Nov  Endorsed by Corvina Ashby \194\183 Calm", page.list.value)
        world.click(page.upload)
        local upload
        for _, frame in ipairs(world.frames) do if frame.name == "LFGPlusUploadFrame" then upload = frame end end
        assert.is_true(upload:IsShown())
        assert.are.equal(records.cases[1].realText .. "\nLFGR1:second", upload.text)
    end)

    it("shows the recent log as copyable text", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("")
        world.click(ns.Window().tabs.log)
        local page = ns.Window().pages.log
        assert.truthy(page.box.value:find("[diag] guid =", 1, true))
        world.click(page.clear)
        assert.are.equal("", page.box.value)
    end)

    it("adds an LFG+ page to Options -> AddOns, through Settings or the older InterfaceOptions", function()
        local world, ns = boot()
        assert.are.equal(1, #world.optionsCategories)
        assert.are.equal("LFG+", world.optionsCategories[1].name)
        assert.are.equal(ns.optionsPanel, world.optionsCategories[1].frame)
        ns.optionsPanel.scripts.OnShow()
        assert.is_true(ns.optionsPanel.settings.prompt:GetChecked())
        world.toggle(ns.optionsPanel.settings.debug)
        assert.is_true(LFGPlusDB.debug)

        local older = boot({ noSettings = true })
        assert.are.equal(1, #older.optionsCategories)
        assert.are.equal("LFG+", older.optionsCategories[1].name)

        local bare, bareNs = boot({ noSettings = true, without = { "InterfaceOptions_AddCategory" } })
        assert.are.equal(0, #bare.optionsCategories)
        assert.is_table(bareNs.optionsPanel) -- built all the same; there's just nowhere to list it
    end)

    it("redraws the Options page when a setting changes while it's open", function()
        local _, ns = boot()
        ns.optionsPanel:Show()
        SlashCmdList.LFGPLUS("prompt")
        assert.is_false(ns.optionsPanel.settings.prompt:GetChecked())
    end)

    it("joins Retail's addon compartment, and leaves it there when the minimap button is hidden", function()
        local _, ns = boot({ interface = 120105, compartment = true,
            units = { player = { name = "Kaelwyn", realm = "Whitemane" } } })
        local entries = AddonCompartmentFrame.registeredAddons
        assert.are.equal(1, #entries)
        assert.are.equal("LFGPlus", entries[1].text)
        assert.are.equal(ns.ICON, entries[1].icon)
        entries[1].func(nil, { buttonName = "LeftButton" }, entries[1])
        assert.is_true(ns.Window():IsShown())
        ns.SetMinimapShown(false)
        assert.are.equal(1, #AddonCompartmentFrame.registeredAddons)
    end)

    it("keeps the button's saved position and hidden state across a reload", function()
        local _, ns = boot(nil, { minimap = { hide = true, minimapPos = 100 } })
        assert.is_false(ns.IsMinimapShown())
        assert.is_false(icon():GetMinimapButton("LFGPlus"):IsShown())
        assert.are.equal(100, LFGPlusDB.minimap.minimapPos)
    end)

    it("registers the minimap button once, however often it's set up", function()
        local _, ns = boot()
        local button = icon():GetMinimapButton("LFGPlus")
        ns.SetupMinimap()
        assert.are.equal(button, icon():GetMinimapButton("LFGPlus"))
    end)

    it("works without the embedded libraries: no minimap button, and the setting still saves", function()
        local _, ns = boot({ noLibs = true })
        assert.is_nil(ns.launcher)
        ns.SetMinimapShown(false)
        assert.is_true(LFGPlusDB.minimap.hide)
        local warned = false
        for _, e in ipairs(LFGPlusLog.entries) do if e.m:find("LibDataBroker-1.1 is missing", 1, true) then warned = true end end
        assert.is_true(warned)
    end)

    it("shows the paste button on the Overview only while unlinked, and what's waiting to upload", function()
        local _, ns = boot()
        SlashCmdList.LFGPLUS("")
        local overview = ns.Window().pages.overview
        assert.is_true(overview.link:IsShown())
        assert.are.equal("Nothing waiting to upload.", overview.waiting:GetText())
        StaticPopupDialogs.LFGPLUS_SETUP.OnAccept({ editBox = { GetText = function() return VALID_CODE end } })
        ns.db.records = { { dir = "given", text = "x", at = 1794096000, name = "Sir Rocky" } }
        -- Shown again (after Escape, say): the open page redraws.
        ns.Window().scripts.OnShow()
        assert.is_false(overview.link:IsShown())
        assert.are.equal("Waiting to upload: 1 given, 0 received.", overview.waiting:GetText())
    end)

    it("says so when the Overview's group button is pressed outside a group", function()
        local world, ns = boot()
        SlashCmdList.LFGPLUS("")
        world.click(ns.Window().pages.overview.group)
        assert.are.equal("You're not in a group.", (world.chat[#world.chat]:gsub("^.-|r ", "")))
    end)

    it("keeps its text boxes read-only: typing puts the text back", function()
        local world, ns = boot()
        ns.db.records = { { dir = "given", text = "x", at = 1794096000, name = "Sir Rocky" } }
        SlashCmdList.LFGPLUS("")
        world.click(ns.Window().tabs.endorsements)
        local list = ns.Window().pages.endorsements.list
        list.box:SetText("typed over")
        list.box.scripts.OnTextChanged(list.box, false) -- set by the addon: kept
        assert.are.equal("typed over", list.box:GetText())
        list.box.scripts.OnTextChanged(list.box, true)  -- typed by the player: put back
        assert.are.equal("08 Nov  You endorsed Sir Rocky", list.box:GetText())
    end)

    it("opens its frames on a client without backdrops, Raise, Escape-to-close or static popups", function()
        local _, ns = boot({ frameWithout = { SetBackdrop = true, Raise = true }, without = { "UISpecialFrames", "StaticPopupDialogs" } })
        assert.is_nil(StaticPopupDialogs)
        SlashCmdList.LFGPLUS("")
        assert.is_true(ns.Window():IsShown())
        ns.db.records = { { dir = "given", text = "LFGR1:x", at = 1794096000, name = "Sir Rocky" } }
        SlashCmdList.LFGPLUS("upload")
        local errors = 0
        for _, e in ipairs(LFGPlusLog.entries) do if e.l == "E" then errors = errors + 1 end end
        assert.are.equal(0, errors)
    end)
end)
