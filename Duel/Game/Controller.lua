-- Controller.lua: wires WoW events into the duel tracker, the ranked handshake,
-- the ledger and the network; owns the derived leaderboard.
local ADDON, ns = ...
local Util, Ledger, Elo, DB = ns.Util, ns.Ledger, ns.Elo, ns.DB

local C = {}
ns.Controller = C
ns.me = ns.me or {}
ns.players, ns.deltas, ns.byBracket, ns.boards = {}, {}, {}, {}

---------------------------------------------------------------------------
-- Output and listeners
---------------------------------------------------------------------------
local PREFIX_TEXT = "|cffe6b422Duel|r "
function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX_TEXT .. msg)
end
function ns.Notify(fmt, ...)
    if ns.db and not ns.db.settings.chat then return end
    ns.Print(fmt, ...)
end
function ns.Debug(fmt, ...)
    if not (ns.db and ns.db.settings.debug) then return end
    local ok, msg = pcall(string.format, fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888[Duel] " .. (ok and msg or fmt) .. "|r")
end

-- On-screen toast (UI/Toast.lua loads later; safe before it exists).
function ns.Toast_(title, text, kind)
    if ns.Toast then pcall(ns.Toast.Show, title, text, kind) end
end

local listeners = {}
function ns.Listen(fn) listeners[#listeners + 1] = fn end
function ns.Fire(event, ...)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, event, ...)
        if not ok then geterrorhandler()(err) end
    end
end

local function serverNow() return GetServerTime and GetServerTime() or time() end
ns.ServerNow = serverNow

---------------------------------------------------------------------------
-- Units and names
---------------------------------------------------------------------------
local readable = function(v) return ns.Transport.Readable(v) end

-- Canonical "First Last" of a player unit. On Forever UnitName may drop the
-- surname, so prefer whichever source gives a two-word name.
function ns.UnitCanon(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local candidates = {}
    if GetUnitName then candidates[#candidates + 1] = GetUnitName(unit, true) end
    local guid = UnitGUID(unit)
    if guid and readable(guid) and GetPlayerInfoByGUID then
        local ok, _, _, _, _, _, name = pcall(GetPlayerInfoByGUID, guid)
        if ok then candidates[#candidates + 1] = name end
    end
    candidates[#candidates + 1] = UnitName(unit)
    local first
    for _, c in ipairs(candidates) do
        local canon = readable(c) and Util.CanonName(c)
        if canon then
            if canon:find(" ", 1, true) then return canon end
            first = first or canon
        end
    end
    return first
end

local SEARCH = { "target", "focus", "mouseover", "party1", "party2", "party3", "party4" }
for i = 1, 40 do SEARCH[#SEARCH + 1] = "nameplate" .. i end
function ns.FindUnit(name)
    for _, unit in ipairs(SEARCH) do
        if UnitExists(unit) and ns.UnitCanon(unit) == name then return unit end
    end
    return nil
end

local function myLevel()
    local l = UnitLevel("player")
    return readable(l) and l or nil
end

---------------------------------------------------------------------------
-- Ledger -> leaderboard
---------------------------------------------------------------------------
local derivePending = false
local function sortBoard(players)
    local board = {}
    for _, p in pairs(players) do board[#board + 1] = p end
    table.sort(board, function(x, y)
        local rx, ry = Ledger.IsRanked(x), Ledger.IsRanked(y)
        if rx ~= ry then return rx end
        if x.r ~= y.r then return x.r > y.r end
        return x.name < y.name
    end)
    for i, p in ipairs(board) do p.rank = Ledger.IsRanked(p) and i or nil end
    return board
end

local function derive()
    derivePending = false
    local byBracket, deltas = ns.ledger:Derive()
    ns.byBracket, ns.deltas = byBracket, deltas
    ns.boards = {}
    for br, players in pairs(byBracket) do ns.boards[br] = sortBoard(players) end
    ns.players = byBracket[ns.MyBracket()] or {}
    ns.Fire("LEDGER")
end

-- The ladder bracket of our current level (10, 20 ... 60).
function ns.MyBracket()
    return Ledger.Bracket(ns.me.level or UnitLevel("player")) or ns.RULES.MIN_LEVEL
end

-- The bracket a player has played most in (for profiles), or ours.
function ns.MainBracket(name)
    local best, games = nil, -1
    for br, players in pairs(ns.byBracket) do
        local p = players[name]
        if p and p.g > games then best, games = br, p.g end
    end
    return best or ns.MyBracket()
end

function ns.OnLedgerChanged(now)
    if now then return derive() end
    if derivePending then return end
    derivePending = true
    C_Timer.After(0.5, derive)
end

function ns.Player(br, name)
    local players = ns.byBracket[br]
    return players and players[name] or { name = name, bracket = br, r = Elo.START, g = 0, counted = 0,
        w = 0, l = 0, peak = Elo.START, hist = {}, nOpp = 0, last = 0, direct = 0,
        class = name == ns.me.name and ns.me.class or nil }
end

function ns.Me(br) return ns.Player(br or ns.MyBracket(), ns.me.name) end

-- Rating change this match would cause once verified (both sides).
function ns.Project(id)
    local r = ns.ledger:Get(id)
    if not r then return nil end
    local ca, cb, dn = r.cf.a, r.cf.b, r.dn
    r.cf.a, r.cf.b, r.dn = math.max(ca, 1), math.max(cb, 1), nil
    local _, deltas = ns.ledger:Derive()
    r.cf.a, r.cf.b, r.dn = ca, cb, dn
    ns.ledger.dirty = true
    return deltas[id], r
end

-- Weight the next ranked game vs opp would get (for the prompt).
function ns.PairWeightNow(opp)
    local a, b = ns.me.name, opp
    if a > b then a, b = b, a end
    local hist, br = {}, ns.MyBracket()
    for _, r in ipairs(ns.ledger:Verified()) do
        if r.a == a and r.b == b and Ledger.MatchBracket(r) == br then
            local d = ns.deltas[r.id]
            if d and d.weight > 0 then hist[#hist + 1] = { r.ts, r.w == "a" and r.a or r.b } end
        end
    end
    return Ledger.PairWeight(hist, serverNow())
end

---------------------------------------------------------------------------
-- Versions
---------------------------------------------------------------------------
local function cmpVersion(a, b)
    local a1, a2, a3 = a:match("^(%d+)%.(%d+)%.(%d+)$")
    local b1, b2, b3 = b:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a1 or not b1 then return 0 end
    a1, a2, a3, b1, b2, b3 = tonumber(a1), tonumber(a2), tonumber(a3), tonumber(b1), tonumber(b2), tonumber(b3)
    if a1 ~= b1 then return a1 - b1 end
    if a2 ~= b2 then return a2 - b2 end
    return a3 - b3
end
local versionTold = false
function ns.NoteVersion(v)
    if versionTold or type(v) ~= "string" then return end
    if cmpVersion(v, ns.VERSION) > 0 then
        versionTold = true
        ns.Print("A newer version (%s) is in use. Please update to keep ranked duels working.", v)
        ns.Toast_("Update available", "Duel Ladder " .. v .. " is in use. Update to keep ranked working.", "warn")
    end
end

---------------------------------------------------------------------------
-- Duel flow
---------------------------------------------------------------------------
local current = {}   -- data about the duel in progress (evidence, unit class)

local function eligible(opp, peer)
    local R = ns.RULES
    local mine = myLevel()
    if not mine or not peer.level then return false, "level" end
    if not R.TEST then
        if mine < R.MIN_LEVEL then return false, "my_level" end
        if peer.level < R.MIN_LEVEL then return false, "their_level" end
        if Ledger.Bracket(mine) ~= Ledger.Bracket(peer.level) then return false, "bracket" end
        if math.abs(mine - peer.level) > R.MAX_LEVEL_GAP then return false, "level_gap" end
    end
    if ns.db.chars[opp] then return false, "own_alt" end
    return true
end

C.REASONS = {
    level = "level unknown", my_level = "ranked starts at level " .. ns.RULES.MIN_LEVEL,
    their_level = "ranked starts at level " .. ns.RULES.MIN_LEVEL,
    bracket = "different level brackets (10-19, 20-29 ... 60)",
    level_gap = "more than " .. ns.RULES.MAX_LEVEL_GAP .. " levels apart",
    own_alt = "that is one of your own characters", they_newer = "opponent runs a newer Duel",
    they_older = "opponent runs an older Duel",
}

local function onRequest(opp, role)
    current = { opp = opp, role = role, startedAt = GetTime() }
    local unit = ns.FindUnit(opp)
    if unit then current.class = select(2, UnitClass(unit)) end
    ns.agreement:Begin(opp, role)
    -- Tell the player on screen whether ranked is even possible.
    C_Timer.After(4, function()
        local s = ns.agreement:Session()
        if s and s.opp == opp and not s.peer then
            ns.Toast_("Casual duel", opp .. " doesn't have Duel Ladder, so this duel can't be ranked.", "warn")
        end
    end)
end

local function onCountdown(opp)
    ns.agreement:Lock()
    -- Server statistics of the opponent, before the fight.
    if ns.Evidence.Supported() then
        ns.Evidence.Read(opp, function(won, lost) current.before = { won = won, lost = lost } end)
    end
end

local function onCancel(opp, reason, state)
    ns.agreement:Cancel()
    if state ~= "requested" then
        ns.Notify("Duel with %s ended without a result (%s). Nothing recorded.", tostring(opp), reason)
        ns.Toast_("Duel cancelled", "No result against " .. tostring(opp) .. " (" .. reason .. "). Nothing recorded.", "info")
        ns.Fire("CANCELLED", opp, reason)
    end
    current = {}
end

local function onResult(res)
    local info = ns.agreement:Finish(res.opp)
    local me = ns.me.name
    local peer = info.peer or {}
    local entry = {
        t = serverNow(), opp = res.opp, result = res.won and "W" or "L", how = res.how,
        mode = "C", class = peer.class or current.class, level = peer.level,
        secs = res.duration and math.floor(res.duration + 0.5) or nil,
        zone = (GetRealZoneText and GetRealZoneText()) or nil,
    }
    local projection
    if info.ranked and info.matchId then
        local rec = Ledger.Validate({ id = info.matchId, ts = entry.t, a = me, b = res.opp,
            w = res.winner == me and "a" or "b", how = res.how, la = myLevel(), lb = peer.level,
            ca = ns.me.class, cb = peer.class }, serverNow())
        if rec then
            local side = Ledger.SideOf(rec, me)
            rec.claim = { a = side == "a", b = side == "b" }
            local before = ns.Me(Ledger.MatchBracket(rec)).r
            ns.ledger:Ingest(rec, nil, me, serverNow())
            local stored = ns.ledger:Get(rec.id)
            ns.Network.SendTo(res.opp, Ledger.Encode(stored), true)
            entry.mode, entry.match, entry.before = "R", rec.id, before
            local d = ns.Project(rec.id)
            if d then
                entry.delta = side == "a" and d.da or d.db
                projection = { before = before, delta = entry.delta, weight = d.weight, why = d.why,
                    oppBefore = side == "a" and d.rb or d.ra, oppDelta = side == "a" and d.db or d.da }
            end
            ns.OnLedgerChanged()
        else
            ns.Debug("ranked record failed validation")
        end
    end
    DB.AddHistory(ns.db, me, entry)
    ns.Fire("RESULT", entry, projection, Ledger.Status(entry.match and ns.ledger:Get(entry.match) or { cf = {} }))

    if entry.mode == "R" then
        local delta = entry.delta or 0
        ns.Notify("%s vs %s - ranked, %s%d (awaiting %s's confirmation)", res.won and "|cff40ff40Victory|r" or "|cffff4040Defeat|r",
            res.opp, delta >= 0 and "+" or "", delta, res.opp)
        -- Unconfirmed after two minutes: say so (it can still verify later via sync).
        local id = entry.match
        C_Timer.After(120, function()
            local r = ns.ledger:Get(id)
            if r and Ledger.Status(r) == "pending" then
                ns.Notify("Ranked result vs %s is still unconfirmed by them. It will count once they confirm.", res.opp)
                ns.Toast_("Result unconfirmed", res.opp .. " hasn't confirmed yet. It will count once they do.", "warn")
                ns.Fire("STATUS", id, "pending")
            end
        end)
    else
        ns.Notify("%s vs %s (casual)", res.won and "|cff40ff40Victory|r" or "|cffff4040Defeat|r", res.opp)
    end

    -- Server statistics after the fight, compared with before.
    local before = current.before
    if before then
        C_Timer.After(3, function()
            ns.Evidence.Read(res.opp, function(won, lost)
                entry.evidence = ns.Evidence.Judge(before, { won = won, lost = lost }, not res.won)
                ns.Fire("HISTORY")
            end)
        end)
    end
    current = {}
end

-- An attestation or sync record was ingested.
local announced = {}
local function onIngest(result, rec, sender)
    if result ~= "new" and result ~= "updated" then return end
    ns.OnLedgerChanged()
    local r = ns.ledger:Get(rec.id)
    if not r then return end
    local status = Ledger.Status(r)
    local mine = Ledger.SideOf(r, ns.me.name)
    if mine and status == "verified" and not announced[r.id] then
        announced[r.id] = true
        -- Our match just verified: final numbers first, then tell the screen, spread it once.
        ns.OnLedgerChanged(true)
        ns.Fire("STATUS", r.id, "verified")
        ns.Network.Broadcast(Ledger.Encode(r))
        C_Timer.After(0.6, function()
            local d = ns.deltas[r.id]
            if d then
                local delta = mine == "a" and d.da or d.db
                for _, e in ipairs(ns.db.history[ns.me.name] or {}) do
                    if e.match == r.id then e.delta = delta end
                end
                local now = ns.Me(Ledger.MatchBracket(r)).r
                ns.Notify("Ranked result vs %s confirmed. Rating %d (%s%d).", mine == "a" and r.b or r.a,
                    now, delta >= 0 and "+" or "", delta)
                ns.Toast_("Ranked result confirmed", string.format("Rating %d (%s%d) vs %s", now,
                    delta >= 0 and "+" or "", delta, mine == "a" and r.b or r.a), "success")
            end
        end)
    elseif mine and status == "disputed" then
        ns.Fire("STATUS", r.id, "disputed")
        ns.Toast_("Result disputed", "The other player reported a different result. It won't count.", "error")
    elseif not mine and Ledger.SideOf(r, sender) == nil then
        -- Second-hand: ask the participants when we can.
        ns.Network.QueueConfirmations(r)
    end
end

function C.OnHandshake(sender, text)
    -- Fallback: a HELLO from someone we challenged though our StartDuel hook missed it.
    if text:sub(1, 2) == "H~" and ns.tracker.state == "idle" then
        local f = Util.Split(text, "~")
        if f[5] == "D" then ns.tracker:RequestOut(sender) end
    end
    ns.agreement:OnMessage(sender, text)
end

---------------------------------------------------------------------------
-- System messages
---------------------------------------------------------------------------
local KO = Util.CompileFormat(DUEL_WINNER_KNOCKOUT or "%1$s has defeated %2$s in a duel")
local FLED = Util.CompileFormat(DUEL_WINNER_RETREAT or "%2$s has fled from %1$s in a duel")
local COUNTDOWN = Util.CountdownPattern(DUEL_COUNTDOWN or "Duel starting: %d")

local function onSystem(msg)
    if not readable(msg) or type(msg) ~= "string" then return end
    local secs = COUNTDOWN and msg:match(COUNTDOWN)
    if secs then return ns.tracker:Countdown(secs) end
    local w, l = Util.MatchFormat(KO, msg)
    local kind = "K"
    if not w then w, l = Util.MatchFormat(FLED, msg); kind = "F" end
    if not w then return end
    w, l = Util.CanonName(w), Util.CanonName(l)
    if w and l then ns.tracker:Winner(kind, w, l) end
end
C.OnSystem = onSystem

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local events = {}

function events.ADDON_LOADED(name)
    if name ~= ADDON then return end
    local db, dropped = DB.Load(DuelDB, serverNow())
    DuelDB = db
    ns.db = db
    if dropped > 0 then
        ns.Print("Dropped %d invalid saved entries.", dropped)
        C_Timer.After(8, function() ns.Toast_("Saved data repaired", dropped .. " invalid entries were dropped.", "warn") end)
    end
end

function events.PLAYER_LOGIN()
    local me = ns.me
    me.name = ns.UnitCanon("player") or Util.CanonName(UnitName("player"))
    me.class = select(2, UnitClass("player"))
    me.level = myLevel()
    local c = ns.db.chars[me.name] or {}
    c.class, c.level, c.seen = me.class, me.level, serverNow()
    c.since = c.since or serverNow()
    ns.db.chars[me.name] = c
    ns.sessionStart = serverNow()

    ns.ledger = Ledger.New(ns.db.matches)
    ns.ledger:Prune(serverNow(), 30 * 86400)
    DB.PrunePeers(ns.db, serverNow(), ns.Network.PEER_KEEP)

    ns.sync = ns.SyncEngine.New({
        ledger = ns.ledger, now = GetTime, serverNow = serverNow,
        selfName = function() return ns.me.name end,
        send = function(peer, line) ns.Network.SendTo(peer, line) end,
        onIngest = onIngest,
    })

    local nonceN = 0
    ns.agreement = ns.Agreement.New({
        now = GetTime,
        nonce = function()
            nonceN = nonceN + 1
            return Util.Base36(math.floor(GetTime() * 1000) % 2176782336, 6)
                .. Util.Base36(math.random(0, 46655), 3) .. Util.Base36(nonceN % 36, 1)
        end,
        myName = function() return ns.me.name end,
        me = function()
            local p = ns.Me()
            return { level = myLevel(), class = ns.me.class, rating = p.r, games = p.g }
        end,
        pref = function() return ns.db.settings.pref end,
        eligible = eligible,
        send = function(target, msg) ns.Network.SendTo(target, msg, true) end,
        onChange = function(session) ns.Fire("SESSION", session) end,
        onNewerVersion = ns.NoteVersion,
    })

    ns.tracker = ns.DuelTracker.New({
        now = GetTime, after = C_Timer.After,
        myName = function() return ns.me.name end,
        onRequest = onRequest, onCountdown = onCountdown, onResult = onResult, onCancel = onCancel,
    })

    ns.Transport.Start()
    ns.Network.Start()
    ns.Directory.Start()
    derive()
    ns.Fire("READY")
    C_Timer.After(6, function()
        local p = ns.Me()
        ns.Toast_("Duel Ladder ready", string.format("%ds bracket rating %d  ·  type /ladder to open", ns.MyBracket(), p.r), "info")
    end)
end

function events.PLAYER_LEVEL_UP(level)
    if readable(level) then
        ns.me.level = level
        if ns.db.chars[ns.me.name] then ns.db.chars[ns.me.name].level = level end
        ns.players = ns.byBracket[ns.MyBracket()] or {}
        if level % ns.RULES.BRACKET_SIZE == 0 and Ledger.Bracket(level) then
            ns.Toast_("New ladder bracket", "You are now in the " .. Ledger.Bracket(level) .. "s bracket: a fresh rating starts at 1500.", "info")
        end
    end
end

function events.DUEL_REQUESTED(challenger)
    if not readable(challenger) then return end
    local name = Util.CanonName(challenger)
    -- The event may give only the first name: find the full one on a unit nearby.
    if name and not name:find(" ", 1, true) then
        for _, unit in ipairs(SEARCH) do
            local full = UnitExists(unit) and ns.UnitCanon(unit)
            if full and full:match("^(%S+)") == name then name = full; break end
        end
    end
    if name then ns.tracker:RequestIn(name) end
end

function events.DUEL_FINISHED() ns.tracker:Finished() end
function events.CHAT_MSG_SYSTEM(msg) onSystem(msg) end

for event in pairs(events) do frame:RegisterEvent(event) end
frame:SetScript("OnEvent", function(_, event, ...) events[event](...) end)

-- We challenged someone: right-click menu and /duel both call StartDuel.
if StartDuel then
    hooksecurefunc("StartDuel", function(arg)
        if not ns.tracker then return end
        -- "/duel selftest", bare "/duel": our commands, not a challenge.
        if ns.Commands and ns.Commands.Intercept(arg) then return end
        local name
        if type(arg) == "string" and readable(arg) and arg ~= "" then
            name = UnitExists(arg) and ns.UnitCanon(arg) or Util.CanonName(arg)
        else
            name = ns.UnitCanon("target")
        end
        if name then ns.tracker:RequestOut(name) end
    end)
end

-- The challenged side accepted: lock shortly after if the countdown line is missed.
if AcceptDuel then
    hooksecurefunc("AcceptDuel", function()
        C_Timer.After(2.5, function()
            if ns.agreement then ns.agreement:Lock() end
        end)
    end)
end

return C
