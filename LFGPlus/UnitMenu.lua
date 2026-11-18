-- "Endorse" and "Copy LFG+ URL" in a player's right-click menu: on the target and party/raid frames, Endorse opens the
-- small endorse popup (UI.lua) for that player, and Copy LFG+ URL shows their profile's address to copy (Slash.lua).
--
-- Uses the game's Menu API (Menu.ModifyMenu), which only adds to Blizzard's menus and so doesn't taint them. Clients
-- without it get no entry, never a patched UnitPopup table (that taints "Set Focus" and friends); /endorse still works.
-- Only menus that come with a unit token: a name from chat or the friends list may not be anyone in range.

local _, ns = ...

ns.UNIT_MENUS = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID" }

--- Adds the LFG+ entries to one opened menu: Endorse for another player we haven't endorsed (or whose endorsement
-- their addon never confirmed), and Copy LFG+ URL for anyone with a profile address, yourself included.
local function addEntry(_, root, context)
    local identity = context and context.unit and ns.UnitIdentity(context.unit)
    if not identity then return end
    local endorsable = not ns.SameCharacter(identity, ns.PlayerIdentity()) and not ns.EndorsementFinal(identity)
    local url = ns.ProfileUrl(identity, ns.gameVersion, ns.RegionId())
    if not endorsable and not url then return end
    root:CreateDivider()
    root:CreateTitle("LFG+")
    if endorsable then root:CreateButton("Endorse", ns.Log.Wrap("ui", function() ns.ShowEndorsePopup(identity) end)) end
    if url then root:CreateButton("Copy LFG+ URL", ns.Log.Wrap("ui", function() StaticPopup_Show("LFGPLUS_COPY_URL", nil, nil, url) end)) end
end

--- Registers the entry with every player menu. Called at PLAYER_LOGIN.
function ns.RegisterUnitMenus()
    if not (Menu and Menu.ModifyMenu) then
        ns.Log.Info("ui", "no Menu API on this client: no Endorse entry in player menus (/endorse still works)")
        return
    end
    for _, tag in ipairs(ns.UNIT_MENUS) do Menu.ModifyMenu(tag, ns.Log.Wrap("ui", addEntry)) end
    ns.Log.Info("ui", "Endorse added to %d player menus", #ns.UNIT_MENUS)
end
