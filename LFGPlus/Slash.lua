-- /lfgplus and /endorse. Plain /lfgplus opens the LFG+ window (Window.lua); /lfgplus help lists the commands.

local _, ns = ...

local VERSION_NAMES = { [10] = "Retail", [20] = "Classic", [30] = "Classic Era", [40] = "WoW Forever", [50] = "TBC Anniversary" }

local function help()
    ns.Print(("v%s on %s."):format(ns.VERSION, VERSION_NAMES[ns.gameVersion or 0] or "an unknown client"))
    for _, line in ipairs(ns.StatusLines()) do ns.Print("  " .. line) end
    ns.Print("  /lfgplus - open the LFG+ window (or click the minimap button)")
    ns.Print("  /lfgplus setup - link your LFG+ account with the setup code from lfg.plus")
    ns.Print("  /lfgplus prompt - ask you to endorse your group after a run (on/off)")
    ns.Print("  /lfgplus sound - play a sound when someone endorses you (on/off)")
    ns.Print("  /lfgplus ack group|guild|friends|others auto|ask - answer endorsement requests automatically, or ask you first")
    ns.Print("  /lfgplus group - endorse the people in your group now")
    ns.Print("  /lfgplus upload - copy your endorsements to paste on lfg.plus")
    ns.Print("  /lfgplus minimap - show or hide the minimap button")
    ns.Print("  /lfgplus reset - delete everything LFG+ keeps on this account")
    ns.Print("  /lfgplus log [count|clear], /lfgplus debug, /lfgplus diag - for troubleshooting")
    ns.Print("  /endorse fun|calm|helpful|leader [quiet] - endorse your target")
end

-- The setup code goes in a dialog, not on the command line, so it never sits in the chat edit box's history.
local function dialogEditBox(dialog)
    return (dialog.GetEditBox and dialog:GetEditBox()) or dialog.editBox or dialog.EditBox
end

--- Links the pasted code. Returns true to keep the dialog open: WoW hides a popup unless OnAccept returns true, so a
-- good code closes it and a bad one leaves it up to be corrected.
local function acceptSetup(dialog)
    local box = dialogEditBox(dialog)
    local ok, message = ns.LinkAccount(box and box:GetText() or "")
    ns.Print(message)
    return not ok
end

if StaticPopupDialogs then
    StaticPopupDialogs.LFGPLUS_SETUP = {
        text = "Paste the setup code from your account page on lfg.plus:",
        button1 = ACCEPT or "Accept",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        editBoxWidth = 320,
        maxLetters = 120,
        OnShow = function(dialog)
            local box = dialogEditBox(dialog)
            if box then box:SetText(""); box:SetFocus() end
        end,
        OnAccept = acceptSetup,
        EditBoxOnEnterPressed = function(box)
            local dialog = box:GetParent()
            if not acceptSetup(dialog) then dialog:Hide() end
        end,
        EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

--- /lfgplus reset, once confirmed: empties LFGPlusDB in place (the client saves that table on reload) and reloads the
-- interface, so every part of the addon starts again from the defaults. The log is kept, with a line saying so.
local function resetEverything()
    for key in pairs(LFGPlusDB) do LFGPlusDB[key] = nil end
    ns.Log.Info("core", "reset: every record and setting deleted")
    ReloadUI()
end

if StaticPopupDialogs then
    StaticPopupDialogs.LFGPLUS_RESET = {
        text = "Delete everything LFG+ keeps on this account: your setup code, settings and every endorsement, uploaded or not? Your interface reloads.",
        button1 = DELETE or "Delete",
        button2 = CANCEL or "Cancel",
        OnAccept = resetEverything,
        showAlert = true,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local TOGGLES = {
    prompt = { key = "promptAfterRuns", on = "Prompt after runs is on.", off = "Prompt after runs is off. You can still use /endorse." },
    sound = { key = "toastSound", on = "Sound for endorsements you get is on.", off = "Sound for endorsements you get is off." },
}

local function ack(args)
    local category, mode = args:match("^(%S+)%s+(%S+)$")
    if category and ns.SetAckMode(category, mode) then
        ns.Print(("%s: %s."):format(ns.ACK_LABELS[category], mode == "ask" and "you'll be asked first" or "answered automatically"))
    else
        ns.Print("Usage: /lfgplus ack group|guild|friends|others auto|ask")
    end
end

SLASH_LFGPLUS1 = "/lfgplus"
local function lfgplus(input)
    local command, args = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command, args = command:lower(), args:lower()
    if command == "" then
        ns.ToggleWindow()
    elseif command == "settings" or command == "options" then
        ns.ToggleWindow("settings")
    elseif command == "minimap" then
        local shown = not ns.IsMinimapShown()
        ns.SetMinimapShown(shown)
        ns.Print(shown and "Minimap button shown." or "Minimap button hidden. /lfgplus minimap brings it back.")
    elseif command == "setup" then
        StaticPopup_Show("LFGPLUS_SETUP")
    elseif command == "reset" then
        StaticPopup_Show("LFGPLUS_RESET")
    elseif command == "unlink" then
        ns.UnlinkAccount()
        ns.Print("Unlinked. Endorsements you give won't be signed until you paste a setup code again.")
        ns.RefreshWindow()
    elseif TOGGLES[command] then
        local toggle = TOGGLES[command]
        ns.Print(ns.ToggleSetting(toggle.key) and toggle.on or toggle.off)
        ns.RefreshWindow()
    elseif command == "ack" then
        ack(args)
        ns.RefreshWindow()
    elseif command == "upload" then
        ns.ShowUpload()
    elseif command == "group" then
        ns.ShowGroupPrompt()
    elseif command == "records" then
        local given, received, carried = ns.WaitingCounts(ns.Now())
        ns.Print(("%s given, %d received and %d from your groups are waiting to be uploaded."):format(
            ns.Plural(given, "endorsement"), received, carried))
    elseif command == "log" then
        if args == "clear" then
            ns.Log.Clear()
            ns.Print("Log cleared.")
        else
            local lines = ns.Log.Recent(tonumber(args) or 20)
            ns.Print(("Last %d of %d log entries (saved to disk on /reload or logout):"):format(#lines, ns.Log.Count()))
            for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end
        end
    elseif command == "debug" then
        ns.Print(ns.ToggleSetting("debug") and "Debug logging on: details go to the log and chat." or "Debug logging off.")
    elseif command == "diag" then
        local d = ns.CollectDiagnostics()
        ns.Print(("Client %s, game version %s, region %s, linked %s."):format(d.buildInfo, d.gameVersion, d.regionId, d.linked))
        ns.Print(("UnitName %s, GUID %s, realm %s."):format(d.unitName, d.guid, d.realmName))
    else
        help()
    end
end

local TAG_WORDS = { fun = 1, calm = 2, helpful = 4, help = 4, leader = 8, lead = 8 }

--- Reads /endorse arguments: a tag word and an optional "quiet". Returns tag (nil when none was given, and
-- ns.Endorse then explains), quiet.
function ns.ParseEndorseArgs(input)
    local tag, quiet = nil, false
    for word in (input or ""):lower():gmatch("%S+") do
        if word == "quiet" then quiet = true elseif TAG_WORDS[word] then tag = TAG_WORDS[word] end
    end
    return tag, quiet
end

SLASH_LFGPLUSENDORSE1 = "/endorse"
local function endorse(input)
    if not UnitExists("target") or not UnitIsPlayer("target") or UnitIsUnit("target", "player") then
        ns.Print("Target another player to endorse them.")
        return
    end
    local tag, quiet = ns.ParseEndorseArgs(input)
    local ok, message = ns.Endorse(ns.UnitIdentity("target"), tag, quiet)
    if not ok then ns.Print(message) end
end

SlashCmdList.LFGPLUS = ns.Log.Wrap("slash", lfgplus)
SlashCmdList.LFGPLUSENDORSE = ns.Log.Wrap("slash", endorse)
