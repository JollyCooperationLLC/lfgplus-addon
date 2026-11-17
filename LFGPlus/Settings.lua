-- Settings behind /lfgplus: linking the account with a setup code, the prompt and sound toggles, and the four
-- ack settings. Plain functions over ns.db, so the specs can drive them.
--
-- Secrets: SavedVariables keep only the pasted setup code (plain text on disk, a known risk in the threat table:
-- rotating on the site invalidates it). The derived keys live in memory, in ns.keys, and nothing here prints either.

local _, ns = ...

ns.ACK_CATEGORIES = { "group", "guild", "friends", "others" }
ns.ACK_LABELS = {
    group = "Party and raid",
    guild = "Guild",
    friends = "Battle.net friends",
    others = "Everyone else",
}
local ACK_MODES = { auto = true, ask = true }

local NOT_A_CODE = "That doesn't look like a setup code. Copy it again from your account page on lfg.plus."

local function useCode(code)
    ns.account = { accountId = code.accountId, keyVersion = code.keyVersion }
    ns.keys = ns.DeriveAddonKeys(code.accountSecret)
end

--- Links the addon to an account from a pasted setup code. Returns true and a message, or false and a message.
function ns.LinkAccount(text)
    local code = ns.ParseSetupCode(text)
    if not code then return false, NOT_A_CODE end
    ns.db.setupCode = (text:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
    useCode(code)
    if ns.RefreshWindow then ns.RefreshWindow() end
    return true, "Linked to your LFG+ account. Endorsements you give from now on can be uploaded."
end

function ns.UnlinkAccount()
    ns.db.setupCode, ns.account, ns.keys = nil, nil, nil
end

function ns.IsLinked()
    return ns.keys ~= nil
end

--- Restores the link at login from the saved code. A saved code that no longer parses (edited by hand, or from an
-- older format) is dropped with a notice rather than kept around half-working.
function ns.LoadAccount()
    ns.account, ns.keys = nil, nil
    local saved = ns.db.setupCode
    if saved == nil then return end
    local code = ns.ParseSetupCode(saved)
    if code then
        useCode(code)
    else
        ns.db.setupCode = nil
        ns.Print("Your saved setup code isn't valid any more. Type /lfgplus setup to paste a new one from lfg.plus.")
    end
end

--- Flips an on/off setting and returns its new value.
function ns.ToggleSetting(name)
    ns.db[name] = not ns.db[name]
    return ns.db[name]
end

--- How to answer an endorsement request from someone in this category: "auto" or "ask".
function ns.AckModeFor(category)
    local mode = ns.db.ack and ns.db.ack[category]
    return ACK_MODES[mode] and mode or "auto"
end

--- Sets one ack category. Returns true, or false for an unknown category or mode.
function ns.SetAckMode(category, mode)
    if not ns.ACK_LABELS[category] or not ACK_MODES[mode] then return false end
    ns.db.ack[category] = mode
    return true
end

local function onOff(value) return value and "on" or "off" end

--- The settings as chat lines, for /lfgplus.
function ns.StatusLines()
    local lines = {
        ns.IsLinked() and "Account: linked." or "Account: not linked. Type /lfgplus setup to paste your setup code from lfg.plus.",
        ("Prompt after runs: %s. Sound for endorsements you get: %s."):format(onOff(ns.db.promptAfterRuns), onOff(ns.db.toastSound)),
    }
    if ns.DataStatusLine then table.insert(lines, 2, ns.DataStatusLine(ns.Now())) end
    local ack = {}
    for _, category in ipairs(ns.ACK_CATEGORIES) do
        ack[#ack + 1] = ("%s %s"):format(ns.ACK_LABELS[category], ns.AckModeFor(category) == "ask" and "ask first" or "automatic")
    end
    lines[#lines + 1] = "Endorsement requests: " .. table.concat(ack, ", ") .. "."
    return lines
end
