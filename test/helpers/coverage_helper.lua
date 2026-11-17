-- Turns on branch counting for one busted run: `busted --coverage --helper=test/helpers/coverage_helper.lua`,
-- as coverage.sh does. Runs before any spec, so the counters outlive busted's per-file insulation. At the end it
-- writes .coverage/lua-branches.tsv: one line per branch site, `file<TAB>line<TAB>kind<TAB>hits`.

local busted = require("busted")
local coverage = require("test.helpers.coverage")

local state = { sites = {}, hits = {} }
rawset(_G, "__LFGCOV", state)
rawset(_G, "__LFGCOV_HIT", function(id) state.hits[id] = state.hits[id] + 1 end)

busted.subscribe({ "suite", "end" }, function()
    local handle = assert(io.open(".coverage/lua-branches.tsv", "wb"))
    for id, site in ipairs(state.sites) do
        handle:write(("%s\t%d\t%s\t%d\n"):format(site.file, site.line, site.kind, state.hits[id]))
    end
    handle:close()
    return nil, true
end)

return coverage
