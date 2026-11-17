-- The LFG+ window (minimap button, /lfgplus) and the LFG+ page in the game's Options → AddOns.
--
--   Overview      link status, data, what's waiting to upload; endorse your group, copy for upload
--   Endorsements  the records held, newest first, and the upload box
--   Settings      account, toggles, minimap button, "ask first" per relationship (also in Options → AddOns)
--   Log           the recent log as copyable text, for bug reports
--
-- The common addon look (Ace3's): the dialog frame from UI.lua, options-style tabs along the top edge of a bordered
-- pane, and the page inside it. Plain frames, the game's own textures and templates every supported client has
-- (UIPanelButtonTemplate, UICheckButtonTemplate, UIPanelScrollFrameTemplate). Every handler is guarded (Log.Wrap).
-- Pages read ns state when shown, and ns.RefreshWindow() redraws the open page when records change.

local _, ns = ...

local WIDTH, HEIGHT = 560, 440
local PANE_TOP = 57                       -- the pane starts below the header and the tabs
local PAD = 12                            -- page inset inside the pane
local CONTENT_WIDTH = WIDTH - 32 - 2 * PAD
local BUTTON_WIDTH = 150
local LOG_LINES = 200
local WHITE = "|cffffffff"

-- The game's options tabs (the same textures Ace3 draws its tabs with): raised when selected.
local TAB_ACTIVE = "Interface\\OptionsFrame\\UI-OptionsFrame-ActiveTab"
local TAB_INACTIVE = "Interface\\OptionsFrame\\UI-OptionsFrame-InActiveTab"
local TAB_HIGHLIGHT = "Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight"
local TAB_WIDTH = 112

local TABS = {
    { key = "overview", label = "Overview" },
    { key = "endorsements", label = "Endorsements" },
    { key = "settings", label = "Settings" },
    { key = "log", label = "Log" },
}

local window

local function text(parent, font, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    return fs
end

local function heading(parent, label)
    local fs = text(parent, "GameFontNormal")
    fs:SetText(label)
    return fs
end

local function checkbox(parent, label, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    -- Our own label: the template's is .text on some clients and .Text on others.
    cb.label = text(cb, "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb.label:SetText(label)
    cb:SetScript("OnClick", ns.Log.Wrap("ui", function(self)
        local checked = self:GetChecked() and true or false
        ns.Log.Info("ui", "setting %q -> %s", label, tostring(checked))
        onChange(checked)
    end))
    return cb
end

--- One options-style tab: inactive and active art (the active one reaches 3px down to cover the pane's top edge), a
-- hover glow, gold text that turns white when selected. SetSelected(on) switches it.
local function newTab(parent, label)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetSize(TAB_WIDTH, 24)
    local function art(file, dy)
        local parts = {}
        for i, piece in ipairs({ { 0, 0.15625, "BOTTOMLEFT" }, { 0.15625, 0.84375 }, { 0.84375, 1, "BOTTOMRIGHT" } }) do
            local t = tab:CreateTexture(nil, "BORDER")
            t:SetTexture(file)
            t:SetTexCoord(piece[1], piece[2], 0, 1)
            t:SetSize(20, 24)
            if piece[3] then t:SetPoint(piece[3], 0, dy) end
            parts[i] = t
        end
        parts[2]:SetPoint("LEFT", parts[1], "RIGHT")
        parts[2]:SetPoint("RIGHT", parts[3], "LEFT")
        return parts
    end
    local inactive, active = art(TAB_INACTIVE, 0), art(TAB_ACTIVE, -3)
    local glow = tab:CreateTexture(nil, "HIGHLIGHT")
    glow:SetTexture(TAB_HIGHLIGHT)
    glow:SetBlendMode("ADD")
    glow:SetPoint("LEFT", 10, -4)
    glow:SetPoint("RIGHT", -10, -4)
    glow:SetHeight(24)
    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tab.label:SetText(label)
    function tab.SetSelected(_, on)
        for i = 1, 3 do
            inactive[i]:SetShown(not on)
            active[i]:SetShown(on)
        end
        tab.label:SetFontObject(on and GameFontHighlightSmall or GameFontNormalSmall)
        tab.label:SetPoint("CENTER", 0, on and -1 or -3)
        tab.selected = on
        -- The selected tab ignores clicks, as the game's tabs do.
        if on then tab:Disable() else tab:Enable() end
    end
    return tab
end

--- The player's own endorsements, given and received, as display lines, newest first.
function ns.RecordLines()
    local lines = {}
    for i = #ns.db.records, 1, -1 do
        local r = ns.db.records[i]
        local label = ns.TagText(r.tags) -- nil for a record saved before tags were a bit field
        local day = (date and r.at) and date("!%d %b", r.at) or ""
        local who = (r.dir == "given" and "You endorsed " or "Endorsed by ") .. tostring(r.name or "?")
        lines[#lines + 1] = ("%s  %s%s"):format(day, who, label and (" \194\183 " .. label) or "")
    end
    return lines
end

-- ─── Settings (shared by the window and Options → AddOns) ────────────────────

local function accountLine()
    return ns.IsLinked() and "Linked to your lfg.plus account."
        or "Not linked. Paste the setup code from your account page on lfg.plus to start endorsing."
end

--- Builds the settings controls into `parent`. Returns a table with the controls and a Refresh function.
local function buildSettings(parent)
    local s = { ack = {} }
    local y = 0
    local function place(widget, height, x)
        widget:SetPoint("TOPLEFT", x or 0, -y)
        y = y + height
    end

    place(heading(parent, "Account"), 20)
    s.account = text(parent, "GameFontHighlight", CONTENT_WIDTH)
    place(s.account, 32)
    s.link = ns.NewButton(parent, "Paste setup code", 140)
    s.link:SetScript("OnClick", ns.Log.Wrap("ui", function() StaticPopup_Show("LFGPLUS_SETUP") end))
    s.unlink = ns.NewButton(parent, "Unlink", 90)
    s.unlink:SetScript("OnClick", ns.Log.Wrap("ui", function()
        ns.UnlinkAccount()
        ns.Print("Unlinked. Endorsements you give won't be signed until you paste a setup code again.")
        s.Refresh()
    end))
    -- Only one of the two shows at a time, so both sit at the left edge.
    s.link:SetPoint("TOPLEFT", 0, -y)
    s.unlink:SetPoint("TOPLEFT", 0, -y)
    y = y + 34

    place(heading(parent, "General"), 22)
    s.prompt = checkbox(parent, "Ask me to endorse my group after a run", function(on) ns.db.promptAfterRuns = on end)
    place(s.prompt, 26)
    s.sound = checkbox(parent, "Play a sound when someone endorses me", function(on) ns.db.toastSound = on end)
    place(s.sound, 26)
    s.thanks = checkbox(parent, "Whisper a thank-you to players I endorse", function(on) ns.db.thankWhisper = on end)
    place(s.thanks, 26)
    s.minimap = checkbox(parent, "Show the minimap button", function(on) ns.SetMinimapShown(on) end)
    place(s.minimap, 26)
    s.debug = checkbox(parent, "Detailed log, for bug reports", function(on)
        ns.db.debug = on
        ns.RefreshWindow() -- shows or hides the Log tab
    end)
    place(s.debug, 34)

    place(heading(parent, "When someone wants to endorse you"), 20)
    local hint = text(parent, "GameFontHighlightSmall", CONTENT_WIDTH)
    hint:SetText("LFG+ accepts automatically. Ask me first when it's someone from:")
    place(hint, 20)
    for i, category in ipairs(ns.ACK_CATEGORIES) do
        local cb = checkbox(parent, ns.ACK_LABELS[category], function(on)
            ns.SetAckMode(category, on and "ask" or "auto")
        end)
        -- Two columns.
        cb:SetPoint("TOPLEFT", (i % 2 == 0) and (CONTENT_WIDTH / 2) or 0, -(y + math.floor((i - 1) / 2) * 26))
        s.ack[category] = cb
    end

    function s.Refresh()
        s.account:SetText(accountLine())
        if ns.IsLinked() then s.link:Hide(); s.unlink:Show() else s.link:Show(); s.unlink:Hide() end
        s.prompt:SetChecked(ns.db.promptAfterRuns and true or false)
        s.sound:SetChecked(ns.db.toastSound and true or false)
        s.thanks:SetChecked(ns.db.thankWhisper and true or false)
        s.minimap:SetChecked(ns.IsMinimapShown())
        s.debug:SetChecked(ns.db.debug and true or false)
        for category, cb in pairs(s.ack) do cb:SetChecked(ns.AckModeFor(category) == "ask") end
    end
    return s
end

-- ─── Pages ───────────────────────────────────────────────────────────────────

local pages = {}

pages.overview = function(page)
    local p = { page = page }
    -- Each line hangs off the one above, so a line that wraps (the unlinked account line) pushes the rest down evenly.
    p.account = text(page, "GameFontHighlight", CONTENT_WIDTH)
    p.account:SetPoint("TOPLEFT", 0, 0)
    local above = p.account
    for _, key in ipairs({ "data", "waiting" }) do
        p[key] = text(page, "GameFontHighlight", CONTENT_WIDTH)
        p[key]:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -10)
        above = p[key]
    end

    -- One row of actions; "Paste setup code" leads it only while unlinked, without leaving a gap once it's hidden.
    p.link = ns.NewButton(page, "Paste setup code", BUTTON_WIDTH)
    p.link:SetPoint("TOPLEFT", p.waiting, "BOTTOMLEFT", 0, -20)
    p.link:SetScript("OnClick", ns.Log.Wrap("ui", function() StaticPopup_Show("LFGPLUS_SETUP") end))
    p.group = ns.NewButton(page, "Endorse your group", BUTTON_WIDTH)
    p.group:SetScript("OnClick", ns.Log.Wrap("ui", function() ns.ShowGroupPrompt() end))
    p.upload = ns.NewButton(page, "Copy for upload", BUTTON_WIDTH)
    p.upload:SetPoint("LEFT", p.group, "RIGHT", 8, 0)
    p.upload:SetScript("OnClick", ns.Log.Wrap("ui", function() ns.ShowUpload() end))

    local about = text(page, "GameFontDisableSmall", CONTENT_WIDTH)
    about:SetPoint("BOTTOMLEFT", 0, 0)
    about:SetText("Endorse the people you'd group with again. Upload your endorsements at lfg.plus/upload so they count.")

    function p.Refresh()
        p.account:SetText(accountLine())
        p.group:ClearAllPoints()
        if ns.IsLinked() then
            p.link:Hide()
            p.group:SetPoint("TOPLEFT", p.waiting, "BOTTOMLEFT", 0, -20)
        else
            p.link:Show()
            p.group:SetPoint("LEFT", p.link, "RIGHT", 8, 0)
        end
        p.data:SetText(ns.DataStatusLine(ns.Now()))
        p.waiting:SetText(ns.WaitingLine() or "Nothing waiting to upload.")
        -- Records already marked uploaded can still be copied again.
        if #ns.UploadLines() > 0 then p.upload:Enable() else p.upload:Disable() end
    end
    return p
end

pages.endorsements = function(page)
    local p = { page = page }
    p.summary = text(page, "GameFontHighlight", CONTENT_WIDTH)
    p.summary:SetPoint("TOPLEFT", 0, 0)
    p.list = ns.NewTextPane(page, "LFGPlusRecordsScroll", CONTENT_WIDTH)
    p.list:SetPoint("TOPLEFT", 0, -22)
    p.list:SetPoint("BOTTOMRIGHT", 0, 32)
    p.upload = ns.NewButton(page, "Copy for upload", BUTTON_WIDTH)
    p.upload:SetPoint("BOTTOMLEFT", 0, 0)
    p.upload:SetScript("OnClick", ns.Log.Wrap("ui", function() ns.ShowUpload() end))
    local hint = text(page, "GameFontDisableSmall", CONTENT_WIDTH - BUTTON_WIDTH - 10)
    hint:SetPoint("LEFT", p.upload, "RIGHT", 10, 0)
    hint:SetText("Upload within 30 days. Older endorsements are removed.")

    function p.Refresh()
        local lines = ns.RecordLines()
        p.summary:SetText(#lines == 0 and "No endorsements yet. Endorse someone after a run, or target them and type /endorse."
            or ("%s held, newest first."):format(ns.Plural(#lines, "endorsement")))
        p.list:SetContent(table.concat(lines, "\n"))
        -- Copies carried for others in our groups aren't listed here, but they're uploaded all the same.
        if #ns.UploadLines() > 0 then p.upload:Enable() else p.upload:Disable() end
    end
    return p
end

pages.settings = function(page)
    return buildSettings(page)
end

pages.log = function(page)
    local p = { page = page }
    p.box = ns.NewTextPane(page, "LFGPlusLogScroll", CONTENT_WIDTH)
    p.box:SetPoint("TOPLEFT", 0, 0)
    p.box:SetPoint("BOTTOMRIGHT", 0, 32)
    p.refresh = ns.NewButton(page, "Refresh", 90)
    p.refresh:SetPoint("BOTTOMLEFT", 0, 0)
    p.refresh:SetScript("OnClick", ns.Log.Wrap("ui", function() p.Refresh() end))
    p.clear = ns.NewButton(page, "Clear", 90)
    p.clear:SetPoint("LEFT", p.refresh, "RIGHT", 8, 0)
    p.clear:SetScript("OnClick", ns.Log.Wrap("ui", function() ns.Log.Clear(); p.Refresh() end))
    local hint = text(page, "GameFontDisableSmall", CONTENT_WIDTH - 200)
    hint:SetPoint("LEFT", p.clear, "RIGHT", 10, 0)
    hint:SetText("Click the text and press Ctrl+A, Ctrl+C to copy it.")

    function p.Refresh()
        p.box:SetContent(table.concat(ns.Log.Recent(LOG_LINES), "\n"))
    end
    return p
end

-- ─── The window ──────────────────────────────────────────────────────────────

local function selectTab(key)
    -- The Log tab is for bug reports: it shows only while debug mode is on (the last tab, so nothing shifts).
    local debug = ns.db.debug and true or false
    if debug then window.tabs.log:Show() else window.tabs.log:Hide() end
    if key == "log" and not debug then key = "overview" end
    window.current = key
    for _, tab in ipairs(TABS) do
        local page = window.pages[tab.key]
        window.tabs[tab.key]:SetSelected(tab.key == key)
        if tab.key == key then
            page.page:Show()
            page.Refresh()
        else
            page.page:Hide()
        end
    end
end

local function buildWindow()
    window = ns.NewFrame("LFGPlusMainFrame", WIDTH, HEIGHT)
    window:SetFrameStrata("HIGH")
    ns.SetFrameTitle(window, ("LFG+  %s%s|r"):format(WHITE, tostring(ns.VERSION)))
    window.pane = ns.NewPane(window)
    window.pane:SetPoint("TOPLEFT", 16, -PANE_TOP)
    window.pane:SetPoint("BOTTOMRIGHT", -16, 16)
    window.tabs, window.pages = {}, {}
    for i, tab in ipairs(TABS) do
        local b = newTab(window, tab.label)
        b:SetPoint("BOTTOMLEFT", window.pane, "TOPLEFT", 6 + (i - 1) * (TAB_WIDTH - 8), 3)
        b:SetScript("OnClick", ns.Log.Wrap("ui", function() selectTab(tab.key) end))
        window.tabs[tab.key] = b

        local page = CreateFrame("Frame", nil, window.pane)
        page:SetPoint("TOPLEFT", PAD, -PAD)
        page:SetPoint("BOTTOMRIGHT", -PAD, PAD)
        window.pages[tab.key] = pages[tab.key](page)
        window.pages[tab.key].page = page
    end
    window:SetScript("OnShow", ns.Log.Wrap("ui", function()
        window.pages[window.current].Refresh() -- ToggleWindow picks a tab before it ever shows the window
    end))
end

--- Opens the window on a tab ("overview" when nil). Closes it instead if it's already open on that tab, so the
-- minimap button toggles it.
function ns.ToggleWindow(tab)
    if not window then buildWindow() end
    if window:IsShown() and (tab == nil or tab == window.current) then
        window:Hide()
        return
    end
    selectTab(tab or window.current or "overview")
    window:Show()
    if window.Raise then window:Raise() end
    ns.Log.Info("ui", "window opened on %s", window.current)
end

--- Redraws the open page (records or settings changed elsewhere).
function ns.RefreshWindow()
    if window and window:IsShown() and window.current then selectTab(window.current) end
    if ns.optionsPanel and ns.optionsPanel:IsShown() then ns.optionsPanel.settings.Refresh() end
end

--- The window, for the specs.
function ns.Window() return window end

--- Opens the post-run prompt for the current group (/lfgplus group, the Overview button).
function ns.ShowGroupPrompt()
    local members = ns.GroupIdentities()
    if #members == 0 then return ns.Print("You're not in a group.") end
    members = ns.NotYetEndorsed(members)
    if #members == 0 then return ns.Print("You've endorsed everyone in your group.") end
    ns.ShowPrompt(members, nil)
end

-- ─── Options → AddOns ────────────────────────────────────────────────────────

local function registerOptions()
    local panel = CreateFrame("Frame", "LFGPlusOptionsPanel")
    panel.name = "LFG+"
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("LFG+")
    local open = ns.NewButton(panel, "Open the LFG+ window", 180)
    open:SetPoint("TOPRIGHT", -16, -12)
    open:SetScript("OnClick", ns.Log.Wrap("ui", function() ns.ToggleWindow("overview") end))
    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 16, -52)
    body:SetPoint("BOTTOMRIGHT", -16, 16)
    panel.settings = buildSettings(body)
    panel:SetScript("OnShow", ns.Log.Wrap("ui", function() panel.settings.Refresh() end))
    ns.optionsPanel = panel

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "LFG+")
        Settings.RegisterAddOnCategory(category)
        ns.optionsCategory = category
        ns.Log.Info("ui", "options registered with Settings")
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
        ns.Log.Info("ui", "options registered with InterfaceOptions")
    else
        ns.Log.Warn("ui", "no options API on this client")
    end
end

if CreateFrame then ns.Log.Guard("ui", registerOptions) end
