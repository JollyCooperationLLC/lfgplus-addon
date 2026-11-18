-- A small fake of the WoW API, enough to load the whole addon in TOC order and drive its events, tooltip hook, slash
-- commands and frames outside the game. Only what the addon touches; extend it when the addon grows.
--
-- Options:
--   interface    the client's TOC number (GetBuildInfo); 16001 is WoW Forever, the default 120105 is Retail
--   units        unit token -> { name =, realm = (or the surname on Forever), guid = }
--   secretNames  UnitName returns a "secret" value (Midnight restricted content)
--   realm        the player's realm name
--   instance     { name =, type = "party", id = 230 } to start inside an instance
--   inCombat     start in combat
--   compartment  the client has Retail's addon compartment (AddonCompartmentFrame)
--   noSettings   the client has no Settings API (falls back to InterfaceOptions_AddCategory)
--   clientRegion GetCurrentRegion's value (1 US, 2 KR, 3 EU, 4 TW, 5 CN); default 1
--   account      "trial" or "veteran": IsTrialAccount() or IsVeteranTrialAccount() is true; "old": the client has
--                neither function; default: both exist and say no
--   clock        the starting GetServerTime
--   noDataAddOn  LoadAddOn finds no data add-on ("MISSING"), or a reason string LoadAddOn gives instead ("DISABLED")
--   emptyDataAddOn  LoadAddOn succeeds but the data add-on registers nothing
--   loadAddOnApi "global": an older client with a global LoadAddOn and no C_AddOns.LoadAddOn; "none": neither
--   addonMessageApi  "global": an older client with global SendAddonMessage / RegisterAddonMessagePrefix and no
--                C_ChatInfo; "none": neither
--   tooltipApi   "hookscript": an older client with no TooltipDataProcessor, so the addon hooks GameTooltip's
--                OnTooltipSetUnit (world.hover runs that hook); "none": neither API
--   raid         the player is in a raid: IsInRaid() is true and the group is the raid1..raidN units
--   instanceGroup  the group is an instance (LFG) group: IsInGroup(LE_PARTY_CATEGORY_INSTANCE) is true
--   encounterApi the client has IsEncounterInProgress, which answers world.encounter
--   groupFinder  "retail": Retail's LFGList tooltip functions exist (listings and applicants); "classic": Classic's
--                LFG browser's listing tooltip. Listings are world.listings[resultID] = { leaderName = }, applicants
--                world.applicants[applicantID] = { member names }. hooksecurefunc always exists.
--
-- The player is dead or a ghost while world.dead is true (UnitIsDeadOrGhost("player")).
--
-- Groups and addon messages: the player is in a group when a partyN or raidN unit exists (IsInGroup). A message sent
-- to a group channel is recorded in world.sent like a whisper and comes straight back as CHAT_MSG_ADDON from the
-- player, the way a real group channel echoes to its sender. world.hear(message, channel, unit) delivers a message
-- from another unit; world.senderName(unit) is the sender string the client would give for it.
--   missingEvents  set of event names this client doesn't have: RegisterEvent errors for them
--
-- Midnight's addon-message lockdown: set world.lockdown = true and C_ChatInfo.InChatMessagingLockdown() says so; set
-- world.refuseNextSend = true and the next send answers 11 (AddOnMessageLockdown) without sending, as when the lockdown
-- begins between the addon's check and its send.
--   frameWithout set of frame method names this client's frames lack (e.g. { SetBackdrop = true, Raise = true })
--   without      list of global names to remove after the fake client is built (e.g. { "UISpecialFrames" })
--   noLibs       world.loadAddon() skips the embedded libraries (Libs/), as if they failed to load

local coverage = require("test.helpers.coverage")

local M = {}

--- A frame that accepts any method: it records text, scripts and shown state, and returns nil for anything else.
local function genericFrame(world, name)
    local frame = { events = {}, scripts = {}, shown = false, name = name, children = {} }
    local methods = {}
    function methods:RegisterEvent(e)
        if world and world.missingEvents and world.missingEvents[e] then error("unknown event " .. e) end
        self.events[e] = true
    end
    function methods:UnregisterEvent(e) self.events[e] = nil end
    function methods:SetScript(kind, fn) self.scripts[kind] = fn; if kind == "OnEvent" then self.onEvent = fn end end
    function methods:GetScript(kind) return self.scripts[kind] end
    function methods:Show() self.shown = true end
    function methods:Hide() self.shown = false end
    function methods:IsShown() return self.shown end
    function methods:SetText(text) self.text = text end
    function methods:GetText() return self.text end
    function methods:CreateFontString() local f = genericFrame(world); f.parent = self; table.insert(self.children, f); return f end
    function methods:CreateTexture() local f = genericFrame(world); f.parent = self; return f end
    function methods:SetTexture(path) self.texture = path end
    function methods:SetVertexColor(r, g, b) self.vertexColor = { r, g, b } end
    function methods:GetFontString() self.fontString = self.fontString or genericFrame(world); return self.fontString end
    function methods:CreateAnimationGroup() local f = genericFrame(world); f.parent = self; return f end
    function methods:CreateAnimation() local f = genericFrame(world); f.parent = self; return f end
    function methods:GetParent() return self.parent end
    function methods:SetChecked(value) self.checked = value and true or false end
    function methods:GetChecked() return self.checked or false end
    function methods:Enable() self.disabled = false end
    function methods:Disable() self.disabled = true end
    function methods:IsEnabled() return not self.disabled end
    function methods:SetSize(w, h) self.width, self.height = w, h end
    function methods:SetHeight(h) self.height = h end
    function methods:GetWidth() return self.width or 0 end
    function methods:GetHeight() return self.height or 0 end
    function methods:GetCenter() return 0, 0 end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:HookScript(kind, fn) self.scripts[kind] = fn end
    -- Unknown CamelCase keys are frame methods (SetSize, SetPoint...): accept them. Lower-case keys are data and stay
    -- nil, as on a real frame.
    setmetatable(frame, { __index = function(_, key)
        if world and world.frameWithout and world.frameWithout[key] then return nil end
        if methods[key] then return methods[key] end
        if type(key) == "string" and key:match("^%u") then return function() return nil end end
        return nil
    end })
    return frame
end
M.genericFrame = genericFrame

function M.install(options)
    options = options or {}
    local world = { chat = {}, frames = {}, tooltipCallbacks = {}, units = options.units or {}, timers = {}, sent = {}, sounds = {} }
    world.clock = options.clock or 1794096000
    world.inCombat = options.inCombat or false
    world.instance = options.instance
    world.missingEvents = options.missingEvents
    world.frameWithout = options.frameWithout

    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) table.insert(world.chat, text) end }
    _G.GetBuildInfo = function() return "x", "1", "Nov 1 2026", options.interface or 120105 end
    if options.account == "old" then
        _G.IsTrialAccount, _G.IsVeteranTrialAccount = nil, nil
    else
        _G.IsTrialAccount = function() return options.account == "trial" end
        _G.IsVeteranTrialAccount = function() return options.account == "veteran" end
    end
    _G.bit = require("bit") -- WoW's bit library; LuaBitOp has the same API
    -- LoadAddOn runs a load-on-demand add-on folder next to LFGPlus/ (the data add-on), like the client does.
    world.loadedAddOns = {}
    local function loadAddOn(name)
        if options.noDataAddOn then return false, options.noDataAddOn == true and "MISSING" or options.noDataAddOn end
        local handle = io.open(name .. "/" .. name .. ".toc")
        if not handle then return false, "MISSING" end
        local toc = handle:read("*a")
        handle:close()
        if not options.emptyDataAddOn then
            for line in toc:gmatch("[^\r\n]+") do
                if not line:match("^#") and line:match("%.lua$") then assert(coverage.load(name .. "/" .. line))() end
            end
        end
        table.insert(world.loadedAddOns, name)
        return true
    end
    _G.C_AddOns = {
        GetAddOnMetadata = function(_, field) return field == "Version" and "0.1.0-test" or nil end,
        LoadAddOn = (options.loadAddOnApi == nil) and loadAddOn or nil,
    }
    _G.LoadAddOn = (options.loadAddOnApi == "global") and loadAddOn or nil
    _G.SlashCmdList = {}
    -- Lua aliases and secure-call helpers the embedded libraries use (Libs/).
    _G.strmatch = string.match
    _G.date = os.date
    _G.securecallfunction = function(fn, ...) return fn(...) end
    _G.LibStub = nil -- each spec loads the libraries afresh
    _G.UIParent = genericFrame(world, "UIParent")
    _G.Minimap = genericFrame(world, "Minimap")
    Minimap.width, Minimap.height = 140, 140
    _G.GetCursorPosition = function() return 0, 0 end
    -- Options → AddOns: the Settings API (Retail and modern classic clients), or the older InterfaceOptions.
    world.optionsCategories = {}
    if options.noSettings then
        _G.Settings = nil
        _G.InterfaceOptions_AddCategory = function(panel) table.insert(world.optionsCategories, { frame = panel, name = panel.name }) end
    else
        _G.InterfaceOptions_AddCategory = nil
        _G.Settings = {
            RegisterCanvasLayoutCategory = function(frame, name) return { frame = frame, name = name, ID = name } end,
            RegisterAddOnCategory = function(category) table.insert(world.optionsCategories, category) end,
        }
    end
    -- Retail's addon compartment (the dropdown by the minimap).
    if options.compartment then
        _G.AddonCompartmentFrame = { registeredAddons = {}, UpdateDisplay = function() end }
        function AddonCompartmentFrame:RegisterAddon(data) table.insert(self.registeredAddons, data) end
    else
        _G.AddonCompartmentFrame = nil
    end
    -- The Menu API (Retail 11.0+ and the classic clients built on it): ModifyMenu keeps each tag's callbacks, and
    -- world.openMenu(tag, contextData) runs them against a fake root description, returning what they added as
    -- { kind = "divider" | "title" | "button", text =, click = }. Remove it with without = { "Menu" }.
    world.menus = {}
    _G.Menu = {
        ModifyMenu = function(tag, fn)
            world.menus[tag] = world.menus[tag] or {}
            table.insert(world.menus[tag], fn)
        end,
    }
    function world.openMenu(tag, context)
        local entries = {}
        local root = {}
        function root:CreateDivider() table.insert(entries, { kind = "divider" }) end
        function root:CreateTitle(text) table.insert(entries, { kind = "title", text = text }) end
        function root:CreateButton(text, click) table.insert(entries, { kind = "button", text = text, click = click }) end
        for _, fn in ipairs(world.menus[tag] or {}) do fn(nil, root, context) end
        return entries
    end
    _G.UISpecialFrames = {}
    _G.LFGPlusLog = nil
    -- StaticPopup: the specs drive a dialog by calling its handlers with a fake dialog and edit box.
    _G.StaticPopupDialogs = {}
    world.popups = {}
    world.popupArgs = {}
    _G.StaticPopup_Show = function(name, a, _, data) table.insert(world.popups, name); table.insert(world.popupArgs, { a = a, data = data }) end
    world.reloads = 0
    _G.ReloadUI = function() world.reloads = world.reloads + 1 end
    _G.CreateFrame = function(_, name, parent)
        local frame = genericFrame(world, name)
        frame.parent = parent
        table.insert(world.frames, frame)
        return frame
    end

    -- Time: GetServerTime follows world.clock; C_Timer callbacks run when a spec calls world.advance(seconds).
    _G.GetServerTime = function() return world.clock end
    _G.C_Timer = { After = function(seconds, fn) table.insert(world.timers, { due = world.clock + seconds, fn = fn }) end }
    function world.advance(seconds)
        local target = world.clock + seconds
        while true do
            table.sort(world.timers, function(a, b) return a.due < b.due end)
            local nextTimer = world.timers[1]
            if not nextTimer or nextTimer.due > target then break end
            table.remove(world.timers, 1)
            world.clock = math.max(world.clock, nextTimer.due)
            nextTimer.fn()
        end
        world.clock = target
    end

    _G.InCombatLockdown = function() return world.inCombat end
    _G.UnitAffectingCombat = function() return world.inCombat end
    _G.IsShiftKeyDown = function() return world.shift or false end
    _G.PlaySound = function(kit) table.insert(world.sounds, kit) end
    _G.SOUNDKIT = { IG_QUEST_LIST_COMPLETE = 618 }

    _G.GetCurrentRegion = function() return options.clientRegion or 1 end
    _G.IsInInstance = function()
        if world.instance then return true, world.instance.type or "party" end
        return false, "none"
    end
    _G.GetInstanceInfo = function()
        local i = world.instance or {}
        return i.name or "Elwynn Forest", i.type or "none", 1, "Normal", 5, 0, false, i.id or 0
    end
    _G.C_Map = {
        GetBestMapForUnit = function() if world.instance then return nil end return 1429 end,
        GetMapInfo = function(id) return { name = "Map " .. id } end,
    }
    _G.GetRealZoneText = function(id) return id and ("Instance " .. id) or "Somewhere" end
    --- The sender string the client gives for a unit's messages: "First Surname" on Forever, "Name-Realm" elsewhere.
    function world.senderName(unit)
        local u = world.units[unit]
        local interface = options.interface or 120105
        if interface >= 16000 and interface < 17000 then return u.realm and (u.name .. " " .. u.realm) or u.name end
        return u.name .. "-" .. (u.realm or GetNormalizedRealmName())
    end
    --- Delivers an LFG+ addon message from a unit ("party1"...) on a channel, as the client would.
    function world.hear(message, channel, unit)
        world.fire("CHAT_MSG_ADDON", "LFGPLUS", message, channel, world.senderName(unit))
    end
    world.lockdown, world.refuseNextSend = false, false
    local function sendAddonMessage(prefix, message, channel, target)
        if world.refuseNextSend then
            world.refuseNextSend = false
            return 11
        end
        table.insert(world.sent, { prefix = prefix, message = message, channel = channel, target = target })
        -- A group channel reaches everyone in the group, the sender included.
        if channel ~= "WHISPER" then world.fire("CHAT_MSG_ADDON", prefix, message, channel, world.senderName("player")) end
        return true
    end
    _G.C_ChatInfo, _G.SendAddonMessage, _G.RegisterAddonMessagePrefix = nil, nil, nil
    if options.addonMessageApi == "global" then
        _G.SendAddonMessage = sendAddonMessage
        _G.RegisterAddonMessagePrefix = function() return true end
    elseif options.addonMessageApi == nil then
        _G.C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return true end,
            SendAddonMessage = sendAddonMessage,
            InChatMessagingLockdown = function() return world.lockdown end,
        }
    end

    local SECRET = setmetatable({}, { __tostring = function() error("attempt to use a secret value") end })
    _G.issecretvalue = function(v) return v == SECRET end
    _G.UnitExists = function(unit) return world.units[unit] ~= nil end
    _G.UnitIsPlayer = function(unit) return world.units[unit] ~= nil end
    _G.UnitIsUnit = function(a, b) return world.units[a] ~= nil and world.units[a] == world.units[b] end
    _G.UnitGUID = function(unit) local u = world.units[unit]; return u and u.guid end
    _G.UnitName = function(unit)
        local u = world.units[unit]
        if not u then return nil end
        if options.secretNames then return SECRET, nil end
        return u.name, u.realm
    end
    _G.UnitInParty = function(name)
        for token, u in pairs(world.units) do
            if token:match("^party") and (u.name == name or (u.realm and (u.name .. " " .. u.realm == name))) then return true end
        end
        return false
    end
    _G.UnitInRaid = function(name)
        if not options.raid then return nil end
        for token, u in pairs(world.units) do
            if token:match("^raid") and (u.name == name or (u.realm and (u.name .. " " .. u.realm == name))) then return 1 end
        end
        return nil
    end
    _G.IsInRaid = function() return options.raid and true or false end
    _G.UnitIsDeadOrGhost = function(unit) return unit == "player" and world.dead or false end
    _G.IsEncounterInProgress = options.encounterApi and function() return world.encounter or false end or nil

    -- hooksecurefunc(name, hook): the global function runs, then the hook, with the same arguments.
    _G.hooksecurefunc = function(name, hook)
        local original = _G[name]
        _G[name] = function(...)
            original(...)
            hook(...)
        end
    end
    world.listings, world.applicants = {}, {}
    _G.C_LFGList = {
        GetSearchResultInfo = function(id) return world.listings[id] end,
        GetApplicantMemberInfo = function(applicantID, memberIdx) return (world.applicants[applicantID] or {})[memberIdx] end,
    }
    _G.LFGListUtil_SetSearchEntryTooltip, _G.LFGListApplicantMember_OnEnter, _G.LFGBrowseSearchEntryTooltip_UpdateAndShow = nil, nil, nil
    if options.groupFinder == "retail" then
        _G.LFGListUtil_SetSearchEntryTooltip = function(tooltip, resultID) tooltip:AddLine("Listing " .. resultID) end
        _G.LFGListApplicantMember_OnEnter = function() GameTooltip:AddLine("Applicant") end
    elseif options.groupFinder == "classic" then
        _G.LFGBrowseSearchEntryTooltip_UpdateAndShow = function(tooltip, resultID) tooltip:AddLine("Listing " .. resultID) end
    end
    -- In a group when there's a party or raid unit. An instance (LFG) group answers for its own category too.
    _G.LE_PARTY_CATEGORY_HOME, _G.LE_PARTY_CATEGORY_INSTANCE = 1, 2
    _G.IsInGroup = function(category)
        if category == LE_PARTY_CATEGORY_INSTANCE and not options.instanceGroup then return false end
        for token in pairs(world.units) do
            if token:match("^party%d") or token:match("^raid%d") then return true end
        end
        return false
    end
    _G.GetNumGroupMembers = function()
        local n = 0
        if options.raid then for token in pairs(world.units) do if token:match("^raid%d+$") then n = n + 1 end end end
        return n
    end
    _G.GetRealmName = function() return options.realm or "Whitemane" end
    _G.GetNormalizedRealmName = function() return ((options.realm or "Whitemane"):gsub("[%s%-]", "")) end

    world.tooltip = { lines = {}, unit = nil }
    function world.tooltip:GetUnit() return "x", self.unit end
    function world.tooltip:AddLine(text, r, g, b) table.insert(self.lines, { text = text, r = r, g = g, b = b }) end
    function world.tooltip:AddDoubleLine(left, right, r, g, b, rr, rg, rb)
        table.insert(self.lines, { text = left, right = right, r = r, g = g, b = b, rr = rr, rg = rg, rb = rb })
    end
    function world.tooltip:Show() end
    world.tooltipScripts = {}
    if options.tooltipApi == "hookscript" then
        function world.tooltip:HookScript(kind, fn) world.tooltipScripts[kind] = fn end
    end
    _G.GameTooltip = world.tooltip
    _G.Enum = { TooltipDataType = { Unit = 2 } }
    _G.TooltipDataProcessor = nil
    if options.tooltipApi == nil then
        _G.TooltipDataProcessor = {
            AddTooltipPostCall = function(kind, fn) world.tooltipCallbacks[kind] = fn end,
        }
    end

    --- Loads every Lua file listed in the TOC, in order, like the client does.
    function world.loadAddon()
        local ns = {}
        local toc = assert(io.open("LFGPlus/LFGPlus.toc")):read("*a")
        for line in toc:gmatch("[^\r\n]+") do
            if not line:match("^#") and line:match("%.lua$") and not (options.noLibs and line:match("^Libs\\")) then
                local chunk = assert(coverage.load(("LFGPlus/" .. line:gsub("\\", "/"))))
                chunk("LFGPlus", ns)
            end
        end
        world.ns = ns
        return ns
    end

    --- Fires an event at every frame that registered it.
    function world.fire(event, ...)
        for _, frame in ipairs(world.frames) do
            if frame.events[event] and frame.onEvent then frame.onEvent(frame, event, ...) end
        end
    end

    function world.fireAddonLoaded()
        world.fire("ADDON_LOADED", "LFGPlus")
    end

    --- Clicks a button: runs its OnClick.
    function world.click(frame, mouseButton)
        assert(frame.scripts.OnClick, "frame has no OnClick")(frame, mouseButton or "LeftButton")
    end

    --- Ticks or unticks a check button the way a click does, then runs its OnClick.
    function world.toggle(frame)
        frame.checked = not frame.checked
        assert(frame.scripts.OnClick, "check button has no OnClick")(frame, "LeftButton")
    end

    --- Tooltip lines as a player reads them: textures left out, a double line's two sides joined by a space.
    function world.texts(lines)
        local texts = {}
        for i, l in ipairs(lines) do
            local text = l.text:gsub("|T[^|]*|t ", "")
            texts[i] = l.right and (text .. " " .. l.right) or text
        end
        return texts
    end

    --- Shows the tooltip for a unit and returns the lines the addon added.
    function world.hover(unit)
        world.tooltip.lines, world.tooltip.unit = {}, unit
        local hook = world.tooltipCallbacks[Enum.TooltipDataType.Unit] or world.tooltipScripts.OnTooltipSetUnit
        if hook then hook(world.tooltip) end
        return world.tooltip.lines
    end

    for _, name in ipairs(options.without or {}) do _G[name] = nil end

    return world
end

return M
