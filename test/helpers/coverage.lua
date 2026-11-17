-- Branch coverage for the addon's own Lua. luacov counts lines; nothing standard counts branches in Lua 5.1,
-- so when the coverage run is on (test/helpers/coverage_helper.lua, `./coverage.sh`), every addon file the specs
-- load is rewritten in memory with a counter on each branch:
--
--   if a then X elseif b then Y else Z end   →   counters after `then`, `then` and `else`
--   if a then X end                          →   counter after `then`, plus `else <counter>` before `end`
--
-- Nothing is inserted across lines, so line numbers (and luacov's line counts) stay exact. `and`/`or` expressions
-- are not counted. Outside the coverage run, load() is plain loadfile().

local M = {}

local KEYWORDS = {
    ["function"] = true, ["if"] = true, ["then"] = true, ["elseif"] = true, ["else"] = true, ["end"] = true,
    ["while"] = true, ["for"] = true, ["do"] = true, ["repeat"] = true, ["until"] = true,
}

--- The source's keyword tokens, skipping strings, long strings and comments. Each is { word =, s =, e = }.
local function keywords(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if src:sub(i, i + 1) == "--" then
            local eq = src:match("^%[(=*)%[", i + 2)
            if eq then
                local _, close = src:find("]" .. eq .. "]", i + 4 + #eq, true)
                i = (close or n) + 1
            else
                local nl = src:find("\n", i, true)
                i = (nl or n) + 1
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then j = j + 2 elseif d == c then break else j = j + 1 end
            end
            i = j + 1
        elseif c == "[" and src:match("^%[=*%[", i) then
            local eq = src:match("^%[(=*)%[", i)
            local _, close = src:find("]" .. eq .. "]", i + 2 + #eq, true)
            i = (close or n) + 1
        elseif c:match("[%a_]") then
            local s, e = src:find("^[%w_]+", i)
            local word = src:sub(s, e)
            -- `t.end` can't occur (keywords aren't field names), but `x:if` can't either; a preceding `.` or `:`
            -- would only ever precede a plain name, so no check is needed.
            if KEYWORDS[word] then out[#out + 1] = { word = word, s = s, e = e } end
            i = e + 1
        elseif c:match("%d") then
            local _, e = src:find("^[%w%.]+", i)
            i = e + 1
        else
            i = i + 1
        end
    end
    return out
end

local function lineAt(src, pos)
    local line = 1
    for _ in src:sub(1, pos - 1):gmatch("\n") do line = line + 1 end
    return line
end

--- Rewrites one file's source with branch counters. Returns the new source and its branch sites { line =, kind = }.
function M.instrument(src, firstId)
    local inserts, sites, stack = {}, {}, {}
    local function counter(pos, kind, prefix)
        local id = firstId + #sites
        sites[#sites + 1] = { id = id, line = lineAt(src, pos), kind = kind }
        inserts[#inserts + 1] = { pos = pos, text = (prefix or " ") .. "__lfgcov(" .. id .. "); " }
    end
    for _, k in ipairs(keywords(src)) do
        local w, top = k.word, stack[#stack]
        if w == "function" then
            stack[#stack + 1] = { kind = "function" }
        elseif w == "if" then
            stack[#stack + 1] = { kind = "if", line = lineAt(src, k.s) }
        elseif w == "then" then
            counter(k.e + 1, top.sawElseif and "elseif" or "then")
        elseif w == "elseif" then
            top.sawElseif = true
        elseif w == "else" then
            top.hasElse = true
            counter(k.e + 1, "else")
        elseif w == "while" or w == "for" then
            stack[#stack + 1] = { kind = "loop", pendingDo = true }
        elseif w == "do" then
            if top and top.pendingDo then top.pendingDo = false else stack[#stack + 1] = { kind = "do" } end
        elseif w == "repeat" then
            stack[#stack + 1] = { kind = "repeat" }
        elseif w == "until" or w == "end" then
            local block = table.remove(stack)
            if w == "end" and block.kind == "if" and not block.hasElse then
                -- The implicit else: reached when every condition was false.
                local id = firstId + #sites
                sites[#sites + 1] = { id = id, line = block.line, kind = "no branch taken" }
                inserts[#inserts + 1] = { pos = k.s, text = "else __lfgcov(" .. id .. "); " }
            end
        end
    end
    assert(#stack == 0, "unbalanced blocks")
    table.sort(inserts, function(a, b) return a.pos > b.pos end)
    local out = src
    for _, ins in ipairs(inserts) do out = out:sub(1, ins.pos - 1) .. ins.text .. out:sub(ins.pos) end
    -- One local on line 1, before anything else, so no line moves.
    return "local __lfgcov = __LFGCOV_HIT; " .. out, sites
end

--- True for the addon's own files: LFGPlus/ (not its embedded Libs/) and the data add-on.
function M.isProduction(path)
    return (path:match("^LFGPlus/") ~= nil and path:match("^LFGPlus/Libs/") == nil) or path:match("^LFGPlus_Data_") ~= nil
end

local cache = {}

--- loadfile() for specs: instruments production files while the coverage run is on.
function M.load(path)
    local state = rawget(_G, "__LFGCOV")
    if not state or not M.isProduction(path) then return loadfile(path) end
    local entry = cache[path]
    if not entry then
        local handle = assert(io.open(path, "rb"))
        local src = handle:read("*a")
        handle:close()
        local instrumented, sites = M.instrument(src, #state.sites + 1)
        for _, site in ipairs(sites) do
            site.file = path
            state.sites[site.id] = site
            state.hits[site.id] = 0
        end
        entry = { src = instrumented }
        cache[path] = entry
    end
    return loadstring(entry.src, "@" .. path)
end

return M
