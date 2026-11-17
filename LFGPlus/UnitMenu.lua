-- "Endorse" in a player's right-click menu: on the target and party/raid
-- frames, it opens the small endorse popup (UI.lua) for that player.
--
-- Uses the game's Menu API (Menu.ModifyMenu), which only adds to Blizzard's menus and so doesn't taint them. Clients
-- without it get no entry, never a patched UnitPopup table (that taints "Set Focus" and friends); /endorse still works.
-- Only menus that come with a unit token: a name from chat or the friends list may not be anyone in range.

local _, ns = ...

ns.UNIT_MENUS = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID" }

--- Adds the LFG+ entry to one opened menu, when it's for another player we can see and haven't endorsed, or whose
-- endorsement their addon never confirmed.
local function addEntry(_, root, context)
    local identity = context and context.unit and ns.UnitIdentity(context.unit)
    if not identity or ns.SameCharacter(identity, ns.PlayerIdentity()) or ns.EndorsementFinal(identity) then return end
    root:CreateDivider()
    root:CreateTitle("LFG+")
    root:CreateButton("Endorse", ns.Log.Wrap("ui", function() ns.ShowEndorsePopup(identity) end))
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
