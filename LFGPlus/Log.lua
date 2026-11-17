-- A small, persistent log for inspecting the addon after a play session.
--
-- Entries live in their own SavedVariable, LFGPlusLog, written to disk by the client on /reload or logout:
--   WTF\Account\<ACCOUNT>\SavedVariables\LFGPlus.lua
-- It's a ring buffer (newest MAX_ENTRIES), so it never grows without bound. /lfgplus log shows the latest entries in
-- chat, /lfgplus log clear empties it, and /lfgplus debug turns verbose entries on.
--
-- Never log secrets: the setup code and the keys stay out (Redact also masks anything that looks like a setup code).
-- Character names and records are fine: this file stays on the player's own computer unless they share it.

local _, ns = ...

local MAX_ENTRIES = 2000
local MAX_MESSAGE = 400

local Log = {}
ns.Log = Log

local LEVELS = { debug = "D", info = "I", warn = "W", error = "E" }

local function now()
    if GetServerTime then return GetServerTime() end
    return os and os.time and os.time() or 0
end

--- The log table, created on first use. Before ADDON_LOADED (file load time) entries go to a temporary table and are
-- merged in once the SavedVariable exists.
local pending = {}
local function store()
    if type(LFGPlusLog) ~= "table" then return nil end
    if type(LFGPlusLog.entries) ~= "table" then LFGPlusLog.entries = {} end
    return LFGPlusLog
end

--- Masks anything that looks like a setup code, wherever it came from.
function Log.Redact(text)
    return (tostring(text):gsub("LFG1:[A-Za-z0-9_%-]+", "LFG1:<redacted>"))
end

local function format(fmt, ...)
    if select("#", ...) == 0 then return tostring(fmt) end
    local ok, text = pcall(string.format, fmt, ...)
    if ok then return text end
    local parts = { tostring(fmt) }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

local function add(level, category, fmt, ...)
    local message = Log.Redact(format(fmt, ...))
    if #message > MAX_MESSAGE then message = message:sub(1, MAX_MESSAGE) .. "…" end
    local entry = { t = now(), l = LEVELS[level], c = category, m = message, s = Log.session }
    local log = store()
    local entries = log and log.entries or pending
    entries[#entries + 1] = entry
    if #entries > MAX_ENTRIES then table.remove(entries, 1) end
    if ns.db and ns.db.debug and DEFAULT_CHAT_FRAME and level ~= "debug" then
        DEFAULT_CHAT_FRAME:AddMessage(("|cff9d9d9dLFG+ [%s] %s|r"):format(category, message))
    end
    return entry
end

--- Verbose entries: only kept while /lfgplus debug is on, so a normal session's log stays readable.
function Log.Debug(category, fmt, ...)
    if not (ns.db and ns.db.debug) then return end
    return add("debug", category, fmt, ...)
end
function Log.Info(category, fmt, ...) return add("info", category, fmt, ...) end
function Log.Warn(category, fmt, ...) return add("warn", category, fmt, ...) end
function Log.Error(category, fmt, ...)
    local entry = add("error", category, fmt, ...)
    -- Say once per session that something went wrong, so a broken feature never fails silently.
    if not Log.errorAnnounced and ns.Print and ns.db then
        Log.errorAnnounced = true
        ns.Print("Something went wrong. Type /lfgplus log to see what, and please send it to us.")
    end
    return entry
end

--- Called from ADDON_LOADED once LFGPlusLog exists: starts a new session and keeps anything logged before that.
function Log.Start(addonVersion)
    LFGPlusLog = type(LFGPlusLog) == "table" and LFGPlusLog or {}
    LFGPlusLog.version = 1
    LFGPlusLog.sessions = (tonumber(LFGPlusLog.sessions) or 0) + 1
    Log.session = LFGPlusLog.sessions
    local entries = store().entries
    for _, entry in ipairs(pending) do
        entry.s = Log.session
        entries[#entries + 1] = entry
    end
    pending = {}
    while #entries > MAX_ENTRIES do table.remove(entries, 1) end
    add("info", "core", "Session %d started, addon v%s", Log.session, tostring(addonVersion))
end

--- Runs fn with error capture: an error is logged with its stack instead of reaching the player. Returns fn's
-- results, or nil after an error.
function Log.Guard(category, fn, ...)
    local handler = function(err)
        local stack = (debugstack and debugstack(2, 12, 0)) or (debug and debug.traceback and debug.traceback("", 2)) or ""
        return tostring(err) .. "\n" .. stack
    end
    -- Lua 5.1's xpcall passes no arguments to fn (5.2 added that), so carry them in a closure.
    local n, args = select("#", ...), { ... }
    local results = { xpcall(function() return fn(unpack(args, 1, n)) end, handler) }
    if results[1] then return unpack(results, 2, table.maxn(results)) end
    Log.Error(category, "%s", results[2])
    return nil
end

--- Wraps a function so every call is guarded. For event handlers, slash commands and button clicks.
function Log.Wrap(category, fn)
    return function(...) return Log.Guard(category, fn, ...) end
end

--- The newest `count` entries as display lines, oldest first.
function Log.Recent(count)
    local log = store()
    local entries = log and log.entries or pending
    local lines = {}
    for i = math.max(1, #entries - (count or 20) + 1), #entries do
        local e = entries[i]
        local stamp = date and date("%H:%M:%S", e.t) or tostring(e.t)
        lines[#lines + 1] = ("%s %s [%s] %s"):format(stamp, e.l or "?", e.c or "?", (e.m or ""):gsub("\n.*", ""))
    end
    return lines
end

function Log.Clear()
    local log = store()
    if log then log.entries = {} end
    pending = {}
end

function Log.Count()
    local log = store()
    return #(log and log.entries or pending)
end
