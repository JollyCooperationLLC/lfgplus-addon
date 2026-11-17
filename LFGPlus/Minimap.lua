-- The minimap button, through the standard embedded libraries (Libs/): LibDataBroker-1.1 describes LFG+ as a
-- "launcher", and LibDBIcon-1.0 draws it on the minimap, lets the player drag it, and on Retail also lists it in the
-- addon compartment menu. Broker displays (Titan Panel, ChocolateBar) pick up the same launcher.
--
-- Left-click opens the LFG+ window, right-click its settings. The button's position and visibility live in
-- LFGPlusDB.minimap, which LibDBIcon reads and writes itself (minimapPos, hide, showInCompartment).

local _, ns = ...

ns.ICON = "Interface\\AddOns\\LFGPlus\\Media\\Icon"
ns.LAUNCHER_NAME = "LFGPlus"

local GREY = { 0.66, 0.70, 0.76 }

local function lib(name)
    return LibStub and LibStub(name, true)
end

--- Lines for the minimap button's tooltip: link status, data, and what's waiting to upload. Pure over ns state.
function ns.LauncherTooltipLines()
    local lines = {
        ns.IsLinked() and "Account linked." or "Account not linked.",
        ns.DataStatusLine(ns.Now()),
    }
    lines[#lines + 1] = ns.WaitingLine() -- nil when nothing waits: no line
    return lines
end

local function onTooltipShow(tooltip)
    tooltip:AddLine("LFG+")
    for _, line in ipairs(ns.LauncherTooltipLines()) do tooltip:AddLine(line, 1, 1, 1) end
    tooltip:AddLine("Click to open. Right-click for settings.", GREY[1], GREY[2], GREY[3])
end

local function onClick(_, mouseButton)
    ns.Log.Debug("ui", "launcher clicked (%s)", tostring(mouseButton))
    if mouseButton == "RightButton" then ns.ToggleWindow("settings") else ns.ToggleWindow() end
end

--- Creates the broker launcher and the minimap button. Called once saved variables exist (Core.lua ADDON_LOADED).
function ns.SetupMinimap()
    local broker, icon = lib("LibDataBroker-1.1"), lib("LibDBIcon-1.0")
    if not broker then
        ns.Log.Warn("ui", "LibDataBroker-1.1 is missing; no minimap button")
        return
    end
    ns.launcher = ns.launcher or broker:NewDataObject(ns.LAUNCHER_NAME, {
        type = "launcher",
        label = "LFG+",
        text = "LFG+",
        icon = ns.ICON,
        OnClick = ns.Log.Wrap("ui", onClick),
        OnTooltipShow = ns.Log.Wrap("ui", onTooltipShow),
    })
    if icon and not icon:IsRegistered(ns.LAUNCHER_NAME) then
        icon:Register(ns.LAUNCHER_NAME, ns.launcher, ns.db.minimap)
        ns.Log.Info("ui", "minimap button registered (%s, compartment %s)", ns.db.minimap.hide and "hidden" or "shown",
            tostring(icon:IsButtonCompartmentAvailable()))
    end
end

function ns.IsMinimapShown()
    return not ns.db.minimap.hide
end

--- Shows or hides the minimap button and remembers it. The compartment entry (Retail) stays either way.
function ns.SetMinimapShown(shown)
    ns.db.minimap.hide = not shown
    local icon = lib("LibDBIcon-1.0")
    if icon then
        if shown then icon:Show(ns.LAUNCHER_NAME) else icon:Hide(ns.LAUNCHER_NAME) end
    end
end
