-- Loads addon files the way the WoW client does: each file is called with (addonName, ns), sharing one ns table.
-- Only pure files belong in specs; files that touch frames need the WoW API and are tested in game.

local coverage = require("test.helpers.coverage")

local M = {}

function M.load(files)
    local ns = {}
    for _, file in ipairs(files) do
        local chunk = assert(coverage.load("LFGPlus/" .. file))
        chunk("LFGPlus", ns)
    end
    return ns
end

--- Reads a JSON test vector. Uses dkjson (a busted dependency of this suite, see .busted / README).
function M.read_vectors(name)
    local json = require("dkjson")
    local handle = assert(io.open("test/test-vectors/" .. name, "rb"))
    local text = handle:read("*a")
    handle:close()
    return assert(json.decode(text))
end

return M
