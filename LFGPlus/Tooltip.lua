-- Adds the LFG+ line to player tooltips, and to the group finder's tooltips for applicants and listings (their names
-- only: the group finder has no unit). It only appends a line of text, which is allowed everywhere, and gives up
-- quietly when the client hides unit data from addons (Midnight's "secret values" in restricted content).

local _, ns = ...

local ENDORSE_R, ENDORSE_G, ENDORSE_B = 0.118, 1.0, 0.0 -- WoW "uncommon" green, #1eff00
local NONE_R, NONE_G, NONE_B = 0.616, 0.616, 0.616     -- WoW "poor" grey, #9d9d9d

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

--- Adds the LFG+ lines for one character: the data line, then your own endorsement of them.
local function addIdentityLines(tooltip, identity)
    local count, tag = ns.LookupCharacter(identity)
    -- Without the data add-on we know nothing about anyone: add no data line rather than "No endorsements yet" for all.
    local dataLine = count ~= nil or ns.HasData()
    -- Your own endorsement of them, real or quiet alike: only this install knows it, and it reads the same.
    local mine = ns.db.endorsed[identity.key]
    -- Unknown players get a grey "No endorsements yet" rather than nothing, so the addon never looks broken on a quiet
    -- realm (planning doc, cold-start risk).
    if count ~= nil then
        tooltip:AddLine(ns.FormatTooltipLine(count, tag), ENDORSE_R, ENDORSE_G, ENDORSE_B)
    elseif dataLine then
        tooltip:AddLine(ns.FormatTooltipLine(nil), NONE_R, NONE_G, NONE_B)
    end
    if mine then tooltip:AddLine(ns.FormatYouEndorsedLine(mine.tags, not dataLine), ENDORSE_R, ENDORSE_G, ENDORSE_B) end
    if dataLine or mine then tooltip:Show() end
end

local function addLine(tooltip, unit)
    if not unit or isSecret(unit) or not UnitIsPlayer(unit) then return end
    -- Identity.lua knows that Forever's UnitName returns (first name, surname), not (name, realm).
    local identity = ns.UnitIdentity(unit)
    if not identity then return end
    addIdentityLines(tooltip, identity)
end

-- A tooltip error must never reach the player: anything unexpected (a new restriction, a missing API on some client)
-- just means no line this time.
local function onUnitTooltip(tooltip)
    if tooltip ~= GameTooltip then return end
    pcall(function()
        local _, unit = tooltip:GetUnit()
        addLine(tooltip, unit)
    end)
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, onUnitTooltip)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", onUnitTooltip)
end

-- ─── The group finder: LFG applicant rows and group-finder listings ────────────────────────────────────────────

--- Adds the LFG+ lines for a name as the group finder gives it: "Name-Realm" ("Name" on our realm), or Forever's
-- "First Surname".
local function addNameLines(tooltip, name)
    local identity = ns.IdentityFromSender(name)
    if identity then addIdentityLines(tooltip, identity) end
end

--- A listing's leader, by search result id.
local function listingLeader(resultID)
    return C_LFGList.GetSearchResultInfo(resultID).leaderName
end

-- The group finder's tooltip functions we add to, by global name. Each client has the ones its group finder uses:
-- Retail's LFGList (listings and applicants), Classic's LFG browser (listings). Every call runs in pcall, so an API
-- a client lacks or changed just means no line.
local GROUP_FINDER_HOOKS = {
    LFGListUtil_SetSearchEntryTooltip = function(tooltip, resultID) addNameLines(tooltip, listingLeader(resultID)) end,
    LFGBrowseSearchEntryTooltip_UpdateAndShow = function(tooltip, resultID) addNameLines(tooltip, listingLeader(resultID)) end,
    LFGListApplicantMember_OnEnter = function(member)
        addNameLines(GameTooltip, C_LFGList.GetApplicantMemberInfo(member:GetParent().applicantID, member.memberIdx))
    end,
}
local hooked = {}

--- Hooks whichever group-finder tooltip functions exist by now, each once. Called at login and whenever an add-on
-- loads, since Blizzard's group finder can load after us.
function ns.HookGroupFinder()
    if not hooksecurefunc then return end
    for name, fn in pairs(GROUP_FINDER_HOOKS) do
        if not hooked[name] and type(_G[name]) == "function" then
            hooksecurefunc(name, function(...) pcall(fn, ...) end)
            hooked[name] = true
            ns.Log.Info("ui", "added the LFG+ line to the group finder's %s", name)
        end
    end
end
