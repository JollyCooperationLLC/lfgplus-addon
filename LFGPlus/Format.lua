-- Text the addon shows. Pure functions only, so the busted suite can check every string.
-- Keep these in step with the tooltip previews on lfg.plus.

local _, ns = ...

-- What players endorse each other for, keyed by tag bit (Record.lua).
ns.TAG_LABELS = {
    [1] = "Fun",
    [2] = "Skilled",
    [4] = "Helpful",
    [8] = "Leader",
}
local TAG_ORDER = { 1, 2, 4, 8 }

-- Each tag's icon: the website's drawings rasterized to white 32px textures (the endorse buttons tint them).
ns.TAG_ICONS = {
    [1] = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Fun",
    [2] = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Skilled",
    [4] = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Helpful",
    [8] = "Interface\\AddOns\\LFGPlus\\Media\\Tag-Leader",
}

local MIDDLE_DOT = "\194\183" -- U+00B7, UTF-8

--- The labels of the tags in a bit field, joined with " · ": "Skilled" today, several once an endorsement may carry
-- more. nil when it holds no known tag.
function ns.TagText(bits)
    local labels = {}
    for _, bit in ipairs(TAG_ORDER) do
        if math.floor((tonumber(bits) or 0) / bit) % 2 == 1 then labels[#labels + 1] = ns.TAG_LABELS[bit] end
    end
    return labels[1] and table.concat(labels, " " .. MIDDLE_DOT .. " ") or nil
end

-- The thank-you whispered to someone you endorse, by tag. Friendly first; "[LFG.plus]" says where it came from.
ns.THANKS_TEXT = {
    [1] = "[LFG.plus] Thanks for the good company, you made that run a blast! I endorsed you as Fun.",
    [2] = "[LFG.plus] Thanks for playing your role so well, you made it look easy. I endorsed you as Skilled.",
    [4] = "[LFG.plus] Thanks for going out of your way to help the group. I endorsed you as Helpful.",
    [8] = "[LFG.plus] Thanks for leading the way and keeping us on track. I endorsed you as Leader.",
}

--- The thank-you for an endorsement's tag, or a plain one for a tag this version doesn't know.
function ns.ThanksText(tags)
    return ns.THANKS_TEXT[tags] or "[LFG.plus] Thanks for the group! I endorsed you."
end

--- A count with its noun: "1 endorsement", "2 endorsements".
function ns.Plural(count, noun)
    return ("%d %s%s"):format(count, noun, count == 1 and "" or "s")
end

--- The tooltip line for someone you've endorsed: "You endorsed them · Skilled", identical for a quiet endorsement.
-- `alone` (no data line above it) adds the "LFG+ " prefix so the line still says where it comes from.
function ns.FormatYouEndorsedLine(tags, alone)
    local label = ns.TagText(tags)
    return (alone and "LFG+ " or "") .. "You endorsed them" .. (label and (" " .. MIDDLE_DOT .. " " .. label) or "")
end

-- The tooltip block for a player in the data: this header, then a row per tag. A player who isn't gets the grey line.
ns.TOOLTIP_HEADER = "LFG+ Endorsements:"
ns.TOOLTIP_NONE = "LFG+ No endorsements yet"

--- The tooltip's rows for a player's four counts (Fun, Skilled, Helpful, Leader): in that order, one per tag someone
-- picked, { the tag's icon and name, its count }, for one double line each. A tag at 0 (or missing) has no row.
function ns.FormatTooltipRows(counts)
    local rows = {}
    for i, bit in ipairs(TAG_ORDER) do
        local count = counts[i] or 0
        if count > 0 then
            rows[#rows + 1] = { ("|T%s:14:14|t %s"):format(ns.TAG_ICONS[bit], ns.TAG_LABELS[bit]), tostring(count) }
        end
    end
    return rows
end
