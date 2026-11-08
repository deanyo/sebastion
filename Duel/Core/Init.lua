-- Init.lua: namespace, constants and pure helpers shared by every module.
-- Nothing in Core/ touches the WoW API at load time, so tests can run it in plain Lua.
local ADDON, ns = ...
ns = ns or {}

ns.ADDON = ADDON or "Duel"
ns.VERSION = "1.1.0"
-- Wire protocol. Bump on any incompatible message change; peers on another
-- protocol are ignored for sync and can only duel casually.
ns.PROTO = 2   -- 2: level brackets
ns.PREFIX = "DuelLadder"          -- addon message prefix (max 16 bytes)
ns.SEASON = 1
ns.SEASON_START = 1793750400       -- 2026-11-04 00:00 UTC, WoW Forever launch

-- Competitive rules. These are part of the deterministic rating replay:
-- every client must use the same values, so they only change with PROTO.
ns.RULES = {
    -- Level brackets: separate ladders for 10-19, 20-29 ... 50-59 and 60.
    -- Ranked needs both players in the same bracket and close in level, so an alt
    -- can only ever touch the ladder of its own bracket.
    MIN_LEVEL = 10,                -- no ranked below this level
    MAX_LEVEL = 60,                -- level cap: its own bracket
    BRACKET_SIZE = 10,
    MAX_LEVEL_GAP = 2,             -- at most this many levels apart
    -- Anti win-trading. A pair = the same two characters.
    PAIR_WINDOW = 86400,           -- repeat-opponent window (24 h)
    PAIR_WEIGHTS = { 1, 0.5, 0.25 },  -- 1st, 2nd, 3rd counted game vs same player in 24 h; then 0
    PAIR_WEEK = 7 * 86400,
    PAIR_WEEK_MAX = 6,             -- counted games vs same player per 7 days
    LOPSIDED_WINDOW = 30 * 86400,
    LOPSIDED_MIN_GAMES = 6,        -- with this many counted games in 30 days...
    LOPSIDED_SHARE = 0.85,         -- ...and one side winning this share, the pair stops counting
    FLED_WEIGHT = 0.5,             -- a duel won because the other player fled
    PROVISIONAL_FARM = 0.5,        -- established player's gains vs a provisional opponent
    MIN_OPPONENTS = 5,             -- distinct counted opponents to be listed as ranked
    MAX_FUTURE_SKEW = 300,         -- reject timestamps further than this in the future
}

local Util = {}
ns.Util = Util

function Util.Trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Plain split (no patterns in sep). Keeps empty fields.
function Util.Split(s, sep)
    local out, i, n = {}, 1, 0
    if s == nil then return out end
    while true do
        local j = string.find(s, sep, i, true)
        n = n + 1
        if not j then out[n] = string.sub(s, i); break end
        out[n] = string.sub(s, i, j - 1)
        i = j + #sep
    end
    return out
end

function Util.Round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return 0 - math.floor(-x + 0.5) + 0  -- never -0
end

function Util.Int(s, lo, hi)
    local n = tonumber(s)
    if not n or n ~= math.floor(n) then return nil end
    if (lo and n < lo) or (hi and n > hi) then return nil end
    return n
end

-- Two cheap 32-bit string hashes using only arithmetic (no bit library needed,
-- every intermediate stays below 2^53 so results are exact everywhere).
local M32 = 4294967296
function Util.Hash32(s, seed)
    local h = seed or 5381
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % M32 end
    return h
end
function Util.Hash32b(s)
    local h = 0
    for i = 1, #s do h = (h * 65599 + string.byte(s, i)) % M32 end
    return h
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
function Util.Base36(n, width)
    n = math.floor(n)
    local out = ""
    repeat
        local d = n % 36
        out = string.sub(DIGITS, d + 1, d + 1) .. out
        n = math.floor(n / 36)
    until n == 0
    if width then
        if #out < width then out = string.rep("0", width - #out) .. out end
        if #out > width then out = string.sub(out, -width) end
    end
    return out
end
function Util.FromBase36(s)
    if type(s) ~= "string" or s == "" or not s:match("^[0-9a-z]+$") then return nil end
    return tonumber(s, 36)
end

local MOD6 = 36 ^ 6
-- 12-char id from any string.
function Util.Id(s)
    return Util.Base36(Util.Hash32(s) % MOD6, 6) .. Util.Base36(Util.Hash32b(s) % MOD6, 6)
end

---------------------------------------------------------------------------
-- Names. WoW Forever characters are "First Last"; the API may append
-- "-Realm". Identity is the name without the realm.
---------------------------------------------------------------------------
function Util.CanonName(name)
    if type(name) ~= "string" then return nil end
    name = Util.Trim(name)
    local dash = name:find("-", 1, true)
    if dash then name = Util.Trim(name:sub(1, dash - 1)) end
    name = name:gsub("%s+", " ")
    if name == "" or #name > 60 then return nil end
    -- Reserved by our wire format, and never part of a real name.
    if name:find("[~,|:%c]") then return nil end
    return name
end

-- Class tokens we accept on the wire (classic + anything uppercase).
function Util.ClassToken(s)
    if type(s) == "string" and s:match("^%u+$") and #s <= 16 then return s end
    return nil
end

---------------------------------------------------------------------------
-- System message parsing (e.g. DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel")
---------------------------------------------------------------------------
-- Compile a client format with two %s / %n$s args into { pattern, order }.
function Util.CompileFormat(fmt)
    if type(fmt) ~= "string" then return nil end
    local order, n = {}, 0
    local p = fmt:gsub("%%(%d?)%$?s", function(idx)
        n = n + 1
        order[n] = tonumber(idx) or n
        return ""
    end)
    if n ~= 2 then return nil end
    p = p:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("", "(.+)")
    return { pattern = "^" .. p .. "$", order = order }
end

-- Returns arg1, arg2 (in format-argument order) or nil.
function Util.MatchFormat(compiled, msg)
    if not compiled or type(msg) ~= "string" then return nil end
    local x, y = msg:match(compiled.pattern)
    if not x then return nil end
    local args = {}
    args[compiled.order[1]], args[compiled.order[2]] = x, y
    return args[1], args[2]
end

-- "Duel starting: %d" -> pattern capturing the seconds.
function Util.CountdownPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p, n = fmt:gsub("%%d", "")
    if n ~= 1 then return nil end
    p = p:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    return "^" .. p:gsub("", "(%%d+)") .. "$"
end

return ns
