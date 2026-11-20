-- The addon's frames: the post-run prompt, the "X endorsed you" toast, the accept popup for "ask first" requests, and
-- the upload box. They can't run outside the game, so every action logs, and every handler is guarded (Log.Wrap):
-- an error is written to the log instead of reaching the player.
--
-- Nothing here appears in combat: the toast and popups wait for PLAYER_REGEN_ENABLED (ns.FlushDeferred).

local _, ns = ...

local GREEN = "|cff1eff00"
local deferred = {}   -- functions waiting for combat to end

local function whenFree(fn)
    if ns.IsBusy() then deferred[#deferred + 1] = fn else fn() end
end

--- Runs everything that waited for combat or an encounter to end.
function ns.FlushDeferred()
    if ns.IsBusy() then return end
    local waiting = deferred
    deferred = {}
    for _, fn in ipairs(waiting) do ns.Log.Guard("ui", fn) end
end

-- The look most addons share (Ace3's frames, and the game's own popups): an opaque dialog background and border, the
-- title in a header on the top edge, and darker bordered panes inside. Every texture ships with every supported client.
local FRAME_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
}
local PANE_BACKDROP = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local HEADER = "Interface\\DialogFrame\\UI-DialogBox-Header"

local function backdrop(frame, spec, r, g, b, a, border)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop(spec)
    frame:SetBackdropColor(r, g, b, a)
    if border then frame:SetBackdropBorderColor(border, border, border) end
end

local function headerPiece(frame, left, right, width)
    local t = frame:CreateTexture(nil, "ARTWORK")
    t:SetTexture(HEADER)
    t:SetTexCoord(left, right, 0, 0.63)
    t:SetSize(width, 40)
    return t
end

--- Sets a frame's title and fits the header around it.
local function setTitle(frame, title)
    frame.title:SetText(title)
    frame.header:SetWidth(math.max(100, (frame.title:GetStringWidth() or 0) + 16))
end

--- A darker bordered pane, for tab contents and lists.
local function newPane(parent)
    local pane = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    backdrop(pane, PANE_BACKDROP, 0.1, 0.1, 0.1, 0.5, 0.4)
    return pane
end

--- A read-only, selectable multi-line text box in a scrolling pane, so the player can copy from it. `width` is the
-- pane's width. SetContent(text) fills it; .value is the text.
local function newTextPane(parent, name, width)
    local pane = newPane(parent)
    local scroll = CreateFrame("ScrollFrame", name, pane, "UIPanelScrollFrameTemplate")
    -- The template's scroll bar hangs off the right edge; leave room for it inside the pane.
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    box:SetWidth(width - 36)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Read-only: put the text back if the player types into it.
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(pane.value or "") self:HighlightText() end
    end)
    scroll:SetScrollChild(box)
    function pane.SetContent(_, value)
        pane.value = value
        box:SetText(value)
    end
    pane.box = box
    return pane
end

local function newFrame(name, width, height)
    local frame = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetToplevel(true) -- clicking it brings it to the front
    backdrop(frame, FRAME_BACKDROP, 0, 0, 0, 1)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    frame.header = headerPiece(frame, 0.31, 0.67, 100)
    frame.header:SetPoint("TOP", 0, 12)
    headerPiece(frame, 0.21, 0.31, 30):SetPoint("RIGHT", frame.header, "LEFT")
    headerPiece(frame, 0.67, 0.77, 30):SetPoint("LEFT", frame.header, "RIGHT")
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOP", frame.header, "TOP", 0, -14)
    if UISpecialFrames then table.insert(UISpecialFrames, name) end -- Escape closes it
    frame:Hide()
    return frame
end

local function button(parent, label, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    return b
end

-- Shared with Window.lua.
ns.NewFrame = newFrame
ns.NewButton = button
ns.NewPane = newPane
ns.NewTextPane = newTextPane
ns.SetFrameTitle = setTitle

-- ─── Post-run prompt ─────────────────────────────────────────────────────────

local VISIBLE_ROWS = 10   -- the prompt's height; a bigger group (a raid) scrolls
local ROW_HEIGHT = 26
-- One button per tag (Format.lua), in display order. No plain Endorse button: every endorsement has a tag.
local TAG_BUTTONS = { 1, 2, 4, 8 }

-- Each button shows its tag's icon (ns.TAG_ICONS, Format.lua), tinted like the button's label.
local LABEL_GOLD = { 1, 0.82, 0 } -- GameFontNormal, the panel button's label colour

--- A prompt button for one tag: its icon on the left, the label beside it.
local function tagButton(row, tag)
    local b = button(row, ns.TAG_LABELS[tag], 108)
    b.tag = tag
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint("LEFT", 12, 0)
    b.icon:SetTexture(ns.TAG_ICONS[tag])
    b.icon:SetVertexColor(LABEL_GOLD[1], LABEL_GOLD[2], LABEL_GOLD[3])
    local label = b:GetFontString()
    label:ClearAllPoints()
    label:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    return b
end

--- Wires `owner.buttons` (tag buttons) to endorse `owner.identity`. After a click that starts an endorsement the
-- buttons give way to "Endorsing…" in `owner.status`; otherwise the player is told why. An owner with `closeOnClick`
-- (the popup) just closes, whatever happened: the handshake is none of the player's business. `source` names the
-- frame in the log.
local function wireTagButtons(owner, source)
    for _, b in ipairs(owner.buttons) do
        b:SetScript("OnClick", ns.Log.Wrap("ui", function(self)
            local quiet = IsShiftKeyDown and IsShiftKeyDown() or false
            local ok, message = ns.Endorse(owner.identity, self.tag, quiet)
            -- Never whether it was quiet: the log shows on screen in debug mode and in the Log tab.
            ns.Log.Info("ui", "%s click: %s tag %d -> %s", source, tostring(owner.identity and owner.identity.name),
                self.tag, ok and "started" or tostring(message))
            if owner.closeOnClick then owner:Hide() end
            if not ok then
                ns.Print(message)
            elseif not owner.closeOnClick then
                for _, other in ipairs(owner.buttons) do other:Hide() end
                owner.status:SetText(GREEN .. "Endorsing…|r")
                owner.status:Show()
            end
        end))
    end
end

local prompt

--- One prompt row: the name, a button per tag, and the status that replaces the buttons once clicked.
local function promptRow(i)
    local row = CreateFrame("Frame", nil, prompt.list)
    row:SetSize(600, 24)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT")
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")
    row.buttons = {}
    local x = 154
    for _, tag in ipairs(TAG_BUTTONS) do
        local b = tagButton(row, tag)
        b:SetPoint("LEFT", x, 0)
        row.buttons[#row.buttons + 1] = b
        x = x + 112
    end
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.status:SetPoint("LEFT", 154, 0)
    wireTagButtons(row, "prompt")
    row:Hide()
    return row
end

local function buildPrompt()
    prompt = newFrame("LFGPlusPromptFrame", 664, 80 + VISIBLE_ROWS * ROW_HEIGHT)
    prompt.hint = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    prompt.hint:SetPoint("TOPLEFT", 20, -34)
    prompt.hint:SetText("Endorse anyone you'd group with again: click what they did best. Shift-click for a quiet endorsement.")
    -- Everyone in one scrolling list, a raid of 40 too; the template's scroll bar sits in the right margin.
    prompt.scroll = CreateFrame("ScrollFrame", "LFGPlusPromptScroll", prompt, "UIPanelScrollFrameTemplate")
    prompt.scroll:SetPoint("TOPLEFT", 20, -56)
    prompt.scroll:SetPoint("BOTTOMRIGHT", -40, 20)
    prompt.list = CreateFrame("Frame", nil, prompt.scroll)
    prompt.list:SetSize(600, ROW_HEIGHT)
    prompt.scroll:SetScrollChild(prompt.list)
    prompt.rows = {}
end

--- Shows the prompt for a list of identities, every one of them (the list scrolls). Waits for combat to end.
function ns.ShowPrompt(members, placeName)
    whenFree(function()
        if not prompt then buildPrompt() end
        setTitle(prompt, placeName and ("Endorse your group from " .. placeName) or "Endorse your group")
        for i = #prompt.rows + 1, #members do prompt.rows[i] = promptRow(i) end
        for i, row in ipairs(prompt.rows) do
            local identity = members[i]
            row.identity = identity
            if identity then
                row.name:SetText(identity.name)
                row.status:Hide()
                for _, b in ipairs(row.buttons) do b:Show() end
                row:Show()
            else
                row:Hide()
            end
        end
        prompt.list:SetHeight(math.max(1, #members) * ROW_HEIGHT)
        prompt.scroll:SetVerticalScroll(0)
        prompt:Show()
        ns.Log.Info("ui", "prompt shown for %d players (%s)", #members, tostring(placeName))
    end)
end

-- ─── Endorse popup (the "Endorse" entry in a player's right-click menu, UnitMenu.lua) ─────────────────────────────

local popup

local function buildPopup()
    popup = newFrame("LFGPlusEndorseFrame", 268, 134)
    popup.hint = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    popup.hint:SetPoint("TOPLEFT", 20, -34)
    popup.hint:SetWidth(228)
    popup.hint:SetJustifyH("LEFT")
    popup.hint:SetText("Click what they did best. Shift-click for a quiet endorsement.")
    popup.buttons = {}
    -- Two by two, in the same order as the prompt's row.
    for i, tag in ipairs(TAG_BUTTONS) do
        local b = tagButton(popup, tag)
        b:SetPoint("TOPLEFT", 20 + ((i - 1) % 2) * 120, -66 - math.floor((i - 1) / 2) * 26)
        popup.buttons[i] = b
    end
    popup.closeOnClick = true
    wireTagButtons(popup, "popup")
end

--- Opens the small endorse popup for one player. Waits for combat to end, like the prompt.
function ns.ShowEndorsePopup(identity)
    whenFree(function()
        if not popup then buildPopup() end
        popup.identity = identity
        setTitle(popup, "Endorse " .. identity.name)
        popup:Show()
        if popup.Raise then popup:Raise() end
        ns.Log.Info("ui", "endorse popup shown for %s", identity.name)
    end)
end

--- The popup, for the specs.
function ns.EndorsePopup() return popup end

--- Marks the prompt row done when its endorsement finishes (called from Endorse.lua).
function ns.OnEndorsementFinished(target, tags)
    local done = GREEN .. "Endorsed \194\183 " .. ns.TagText(tags) .. "|r"
    if not prompt or not prompt:IsShown() then return end
    for _, row in ipairs(prompt.rows) do
        if row.identity and ns.SameCharacter(row.identity, target) then row.status:SetText(done) end
    end
end

-- ─── Toast ───────────────────────────────────────────────────────────────────

local toast
local toastQueue = {}

local function placeName(kind, id)
    if kind == 2 and C_Map and C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(id)
        return info and info.name
    end
    if kind == 1 and GetRealZoneText then
        local ok, name = pcall(GetRealZoneText, id)
        if ok and name and name ~= "" then return name end
    end
    return nil
end
ns.PlaceName = placeName

local function playSound()
    if not ns.db.toastSound or not PlaySound then return end
    local kit = SOUNDKIT and (SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.READY_CHECK)
    if kit then pcall(PlaySound, kit, "Master") end
end

local function showNextToast()
    if not toast then
        toast = CreateFrame("Frame", "LFGPlusToast", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        toast:SetSize(360, 46)
        toast:SetPoint("TOP", 0, -140)
        toast:SetFrameStrata("HIGH")
        backdrop(toast, PANE_BACKDROP, 0, 0, 0, 0.85, 0.6) -- a dialog border is too heavy for one line
        toast.text = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        toast.text:SetPoint("CENTER")
        toast.text:SetWidth(340)
        toast:Hide()
    end
    if toast:IsShown() or #toastQueue == 0 then return end
    local line = table.remove(toastQueue, 1)
    toast.text:SetText(GREEN .. "LFG+|r " .. line)
    toast:SetAlpha(1)
    toast:Show()
    playSound()
    C_Timer.After(5, ns.Log.Wrap("timer:toast", function()
        toast:Hide()
        whenFree(showNextToast)
    end))
end

--- "Corvina Ashby endorsed you · Skilled · Blackrock Depths". Identical for real and quiet records.
function ns.EndorsedToastText(rec)
    local parts = { rec.endorser.name .. " endorsed you", ns.TagText(rec.tags) }
    local place = placeName(rec.locationKind, rec.locationId)
    if place then parts[#parts + 1] = place end
    return table.concat(parts, " \194\183 ")
end

function ns.ShowEndorsedToast(rec)
    local line = ns.EndorsedToastText(rec)
    toastQueue[#toastQueue + 1] = line
    ns.Print(line .. ".")
    whenFree(showNextToast)
end

-- ─── "Ask first" popup ───────────────────────────────────────────────────────

if StaticPopupDialogs then
    StaticPopupDialogs.LFGPLUS_ACK = {
        text = "%s wants to endorse you.",
        button1 = ACCEPT or "Accept",
        button2 = IGNORE or "Ignore",
        OnAccept = function(_, data)
            ns.Log.Guard("ui", function()
                ns.Log.Info("ui", "accepted request %d from %s", data.request.counter, data.request.endorser.name)
                ns.SendAck(data.request, data.bytes, data.sender)
            end)
        end,
        OnCancel = function(_, data)
            if data then ns.Log.Info("ui", "ignored request %d from %s", data.request.counter, data.request.endorser.name) end
        end,
        timeout = 60,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

--- Asks before acknowledging a request (the "ask first" ack setting). Never in combat.
function ns.AskToAck(request, bytes, sender)
    whenFree(function()
        StaticPopup_Show("LFGPLUS_ACK", request.endorser.name, nil, { request = request, bytes = bytes, sender = sender })
    end)
end

-- ─── Upload box ──────────────────────────────────────────────────────────────

local upload

local function buildUpload()
    upload = newFrame("LFGPlusUploadFrame", 560, 360)
    setTitle(upload, "Upload your endorsements")
    upload.hint = upload:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    upload.hint:SetPoint("TOPLEFT", 20, -34)
    upload.hint:SetWidth(520)
    upload.hint:SetJustifyH("LEFT")
    upload.pane = newTextPane(upload, "LFGPlusUploadScroll", 520)
    upload.pane:SetPoint("TOPLEFT", 20, -54)
    upload.pane:SetPoint("BOTTOMRIGHT", -20, 50)
    upload.box = upload.pane.box
    upload.box:SetScript("OnEscapePressed", function() upload:Hide() end)
    -- Shown when the records don't fit one paste: the site takes 500 at a time.
    upload.next = button(upload, "Next part", 140)
    upload.next:SetPoint("TOPRIGHT", -40, -28)
    upload.next:SetScript("OnClick", ns.Log.Wrap("ui", function() ns.ShowUpload(upload.part + 1) end))
    -- After pasting: what the box held stops counting as waiting, and leaves the box.
    upload.done = button(upload, "I uploaded these", 140)
    upload.done:SetPoint("BOTTOMRIGHT", -20, 20)
    upload.done:SetScript("OnClick", ns.Log.Wrap("ui", function()
        ns.MarkUploaded(upload.seq)
        upload:Hide()
    end))
end

--- Shows the upload box with one paste's worth of records: `part` (from 1) of however many the site needs; past the
-- last part it starts again at the first.
function ns.ShowUpload(part)
    local parts = ns.UploadParts()
    if #parts == 0 then
        ns.Print("Nothing is waiting to upload.")
        return
    end
    if not upload then buildUpload() end
    part = (part and part <= #parts) and part or 1
    local lines = parts[part]
    upload.part = part
    -- Everything stored by now is in the box, in one part or another: "I uploaded these" marks up to here.
    upload.seq = ns.db.lastSeq
    upload.text = table.concat(lines, "\n")
    local copy = "Press Ctrl+C to copy, then paste on lfg.plus/upload."
    if #parts == 1 then
        upload.hint:SetText(("%s. %s"):format(ns.Plural(#lines, "endorsement"), copy))
        upload.next:Hide()
    else
        upload.hint:SetText(("Part %d of %d: %s. %s"):format(part, #parts, ns.Plural(#lines, "endorsement"), copy))
        upload.next:SetText(part < #parts and ("Next part (%d of %d)"):format(part + 1, #parts) or "Back to part 1")
        upload.next:Show()
    end
    -- On the last part: by then every part has been copied.
    if part == #parts then upload.done:Show() else upload.done:Hide() end
    upload.pane:SetContent(upload.text)
    upload:Show()
    if upload.Raise then upload:Raise() end
    upload.box:SetFocus()
    upload.box:HighlightText()
    ns.Log.Info("ui", "upload box shown: part %d of %d, %d records", part, #parts, #lines)
end
