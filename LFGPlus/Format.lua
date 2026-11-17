-- Text the addon shows. Pure functions only, so the busted suite can check every string.
-- Keep these in step with the tooltip previews on lfg.plus.

local _, ns = ...

-- What players endorse each other for, keyed by tag bit (Record.lua).
ns.TAG_LABELS = {
    [1] = "Fun",
    [2] = "Calm",
    [4] = "Helpful",
    [8] = "Leader",
}
local TAG_ORDER = { 1, 2, 4, 8 }

local MIDDLE_DOT = "\194\183" -- U+00B7, UTF-8

--- The labels of the tags in a bit field, joined with " · ": "Calm" today, several once an endorsement may carry
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
    [2] = "[LFG.plus] Thanks for keeping your cool, even when things went sideways. I endorsed you as Calm.",
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

--- The tooltip line for someone you've endorsed: "You endorsed them · Calm", identical for a quiet endorsement.
-- `alone` (no data line above it) adds the "LFG+ " prefix so the line still says where it comes from.
function ns.FormatYouEndorsedLine(tags, alone)
    local label = ns.TagText(tags)
    return (alone and "LFG+ " or "") .. "You endorsed them" .. (label and (" " .. MIDDLE_DOT .. " " .. label) or "")
end

--- The tooltip line: "LFG+ Endorsed by 27 · Calm", or "LFG+ No endorsements yet" when count is nil.
function ns.FormatTooltipLine(count, tag)
    if count == nil then return "LFG+ No endorsements yet" end
    local line = "LFG+ Endorsed by " .. tostring(count)
    local label = ns.TAG_LABELS[tag or 0]
    if label then line = line .. " " .. MIDDLE_DOT .. " " .. label end
    return line
end
