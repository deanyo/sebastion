-- DB.lua: SavedVariables layout, defaults, migration and validation. Pure logic.
--
-- DuelDB (account-wide) = {
--   schema   = 1,
--   matches  = { [id] = ledger record },     -- the shared ranked ledger
--   history  = { [character] = { entries } },-- this account's own duels, casual included
--   chars    = { [character] = { class, level, seen } },  -- our own characters (no alt duels)
--   peers    = { [name] = { seen, version } },
--   settings = { ... }, ui = { ... }, stats = { dropped = n }
-- }
-- Anything that fails validation on load is dropped and counted, never trusted.
local _, ns = ...
local Util, Ledger = ns.Util, ns.Ledger

local DB = {}
ns.DB = DB

DB.SCHEMA = 1
DB.HISTORY_MAX = 500
DB.PEERS_MAX = 2000

DB.DEFAULTS = {
    pref = "ask",          -- ranked preference: ask | ranked | casual
    minimap = true,
    minimapAngle = 215,
    resultScreen = true,
    chat = true,
    sound = true,
    guildShare = true,     -- announce/sync over guild addon chat
    directory = true,      -- hidden channel member list as a peer directory
    bnet = true,           -- sync with Battle.net friends on Forever
    hideUnvouched = false, -- leaderboard: hide players nobody vouched for directly
    debug = false,
}

local function sanitizeRecord(id, r, now)
    if type(r) ~= "table" or r.id ~= id then return nil end
    local v = Ledger.Validate(r, now)
    if not v then return nil end
    -- Validate sorts names; a stored record must already be sorted.
    if v.a ~= r.a then return nil end
    local cf = type(r.cf) == "table" and r.cf or {}
    v.cf = { a = Util.Int(cf.a, 0, 2) or 0, b = Util.Int(cf.b, 0, 2) or 0 }
    if type(r.dn) == "table" and (r.dn.a == true or r.dn.b == true) then
        v.dn = { a = r.dn.a == true or nil, b = r.dn.b == true or nil }
    end
    v.src = Util.CanonName(r.src)
    v.seen = Util.Int(r.seen, 0, nil)
    return v
end

local function sanitizeEntry(e)
    if type(e) ~= "table" then return nil end
    local opp = Util.CanonName(e.opp)
    local t = Util.Int(e.t, 0, nil)
    if not opp or not t or (e.result ~= "W" and e.result ~= "L") then return nil end
    return {
        t = t, opp = opp, result = e.result,
        how = (e.how == "K" or e.how == "F") and e.how or nil,
        mode = (e.mode == "R" or e.mode == "C") and e.mode or "C",
        class = Util.ClassToken(e.class), level = Util.Int(e.level, 0, 200),
        match = type(e.match) == "string" and #e.match == 12 and e.match or nil,
        secs = Util.Int(e.secs, 0, 100000), zone = type(e.zone) == "string" and e.zone:sub(1, 60) or nil,
        before = Util.Int(e.before, 0, 5000), delta = Util.Int(e.delta, -1000, 1000),
    }
end

-- Returns the cleaned database (same table when possible) and how many items were dropped.
function DB.Load(saved, now)
    local dropped = 0
    if type(saved) ~= "table" then saved = {} end
    if saved.schema ~= nil and saved.schema ~= DB.SCHEMA then
        -- Only schema 1 exists; an unknown schema is from a newer build. Keep its
        -- matches if they validate, reset everything else.
        saved = { matches = saved.matches, settings = saved.settings }
    end
    saved.schema = DB.SCHEMA

    local matches = {}
    if type(saved.matches) == "table" then
        for id, r in pairs(saved.matches) do
            local v = type(id) == "string" and sanitizeRecord(id, r, now)
            if v then matches[id] = v else dropped = dropped + 1 end
        end
    end
    saved.matches = matches

    local settings = type(saved.settings) == "table" and saved.settings or {}
    for k, def in pairs(DB.DEFAULTS) do
        if type(settings[k]) ~= type(def) then settings[k] = def end
    end
    if settings.pref ~= "ask" and settings.pref ~= "ranked" and settings.pref ~= "casual" then settings.pref = "ask" end
    saved.settings = settings

    local history = {}
    if type(saved.history) == "table" then
        for who, list in pairs(saved.history) do
            local name = Util.CanonName(who)
            if name and type(list) == "table" then
                local clean = {}
                for _, e in ipairs(list) do
                    local v = sanitizeEntry(e)
                    if v then clean[#clean + 1] = v else dropped = dropped + 1 end
                end
                while #clean > DB.HISTORY_MAX do table.remove(clean, 1) end
                history[name] = clean
            end
        end
    end
    saved.history = history

    local chars = {}
    if type(saved.chars) == "table" then
        for who, c in pairs(saved.chars) do
            local name = Util.CanonName(who)
            if name and type(c) == "table" then
                chars[name] = { class = Util.ClassToken(c.class), level = Util.Int(c.level, 0, 200), seen = Util.Int(c.seen, 0, nil) }
            end
        end
    end
    saved.chars = chars

    local peers, n = {}, 0
    if type(saved.peers) == "table" then
        for who, p in pairs(saved.peers) do
            local name = Util.CanonName(who)
            if name and type(p) == "table" and n < DB.PEERS_MAX then
                peers[name] = { seen = Util.Int(p.seen, 0, nil) or 0,
                    version = type(p.version) == "string" and p.version:sub(1, 16) or nil }
                n = n + 1
            end
        end
    end
    saved.peers = peers

    saved.ui = type(saved.ui) == "table" and saved.ui or {}
    saved.stats = type(saved.stats) == "table" and saved.stats or {}
    saved.stats.dropped = (Util.Int(saved.stats.dropped, 0, nil) or 0) + dropped
    return saved, dropped
end

function DB.AddHistory(db, who, entry)
    local list = db.history[who]
    if not list then list = {}; db.history[who] = list end
    list[#list + 1] = entry
    while #list > DB.HISTORY_MAX do table.remove(list, 1) end
    return entry
end

-- Forget peers not heard from in maxAge seconds.
function DB.PrunePeers(db, now, maxAge)
    for name, p in pairs(db.peers) do
        if now - (p.seen or 0) > maxAge then db.peers[name] = nil end
    end
end

return DB
