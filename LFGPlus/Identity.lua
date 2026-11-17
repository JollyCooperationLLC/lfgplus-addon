-- Who a character is, per game version.
--
-- WoW Forever is realmless: UnitName(unit) returns (first name, surname), the full name "First Surname" is unique per
-- region, and whispers address "First Surname". Every other version returns (name, realm), with realm nil for your own
-- realm, and addresses "Name-Realm".
--
-- An identity is { name = display name, realm = normalized realm or "", guid = UnitGUID or nil, key = lookup key }.

local _, ns = ...

-- GetCurrentRegion(): 1 US, 2 KR, 3 EU, 4 TW, 5 CN. The site's regions: 1 US, 2 EU, 3 KR, 4 TW.
local REGION_BY_CLIENT = { [1] = 1, [2] = 3, [3] = 2, [4] = 4 }
ns.REGION_CODES = { [1] = "us", [2] = "eu", [3] = "kr", [4] = "tw" }

--- Our region number, or nil where LFG+ doesn't run (China, or an unknown value).
function ns.RegionId()
    local client = GetCurrentRegion and GetCurrentRegion()
    return REGION_BY_CLIENT[client or 0]
end

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

function ns.IsRealmless()
    return ns.gameVersion == ns.GameVersions.FOREVER
end

--- The lookup key for a name and realm: lower case, single spaces. Forever keys have no realm.
function ns.CharacterKey(name, realm)
    local key = tostring(name or ""):lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if realm and realm ~= "" then key = key .. "-" .. tostring(realm):lower() end
    return key
end

--- A realm as the game spells it inside names and keys: no spaces or hyphens ("Aerie Peak" -> "AeriePeak",
-- "Azjol-Nerub" -> "AzjolNerub"), as GetNormalizedRealmName does. Apostrophes stay ("Mal'Ganis").
function ns.NormalizeRealm(realm)
    return (tostring(realm or ""):gsub("[%s%-]", ""))
end

local function ownRealm()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and ns.NormalizeRealm(GetRealmName())) or ""
end

--- Builds an identity from the two values UnitName returns.
function ns.IdentityFromParts(first, second, guid)
    if not first or first == "" then return nil end
    local name, realm
    if ns.IsRealmless() then
        name = (second and second ~= "") and (first .. " " .. second) or first
        realm = ""
    else
        name = first
        -- A cross-realm unit's realm can come with its spaces ("Aerie Peak"); keys and whispers use "AeriePeak".
        realm = (second and second ~= "") and ns.NormalizeRealm(second) or ownRealm()
    end
    return { name = name, realm = realm, guid = guid, key = ns.CharacterKey(name, realm) }
end

--- The identity of a unit token ("player", "target", "party1"...), or nil when it isn't a visible player or the client
-- hides its name (secret values in restricted content).
function ns.UnitIdentity(unit)
    if not unit or isSecret(unit) or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local first, second = UnitName(unit)
    if not first or isSecret(first) or isSecret(second) or first == UNKNOWNOBJECT then return nil end
    local guid = UnitGUID and UnitGUID(unit)
    if isSecret(guid) then guid = nil end
    return ns.IdentityFromParts(first, second, guid)
end

--- The identity of an addon-message or whisper sender: "First Surname" on Forever, "Name-Realm" elsewhere.
function ns.IdentityFromSender(sender)
    if type(sender) ~= "string" or sender == "" or isSecret(sender) then return nil end
    if ns.IsRealmless() then
        local name = sender:gsub("%-.*$", "") -- tolerate a realm suffix some clients may add
        return { name = name, realm = "", key = ns.CharacterKey(name, "") }
    end
    local name, realm = sender:match("^([^%-]+)%-(.+)$")
    if name then realm = ns.NormalizeRealm(realm) else name, realm = sender, ownRealm() end
    return { name = name, realm = realm, key = ns.CharacterKey(name, realm) }
end

--- The name to whisper an identity by.
function ns.WhisperTarget(identity)
    if ns.IsRealmless() or not identity.realm or identity.realm == "" then return identity.name end
    return identity.name .. "-" .. identity.realm
end

--- True when two identities are the same character.
function ns.SameCharacter(a, b)
    return a ~= nil and b ~= nil and a.key == b.key
end
