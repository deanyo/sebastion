-- Ledger.lua: the shared list of ranked matches and the ratings derived from it.
-- Pure logic, no WoW API.
--
-- Trust model (see docs/DESIGN.md):
--   * A match record names two participants (a < b, sorted) and a winner.
--   * Each participant confirms (attests) the record. The game authenticates the
--     sender of a whisper/guild/party addon message, so an attestation received
--     straight from a participant is "direct" (cf = 2). A confirmation carried by
--     somebody else is only a claim (cf = 1).
--   * verified = both participants confirmed (direct or claimed) and no participant
--     disputed it directly. Only verified records feed ratings.
--   * Ratings are never taken from the network: every client replays the verified
--     records in (ts, id) order. Same records in, same ratings out.
-- A relayed claim can be forged by a modified client; the UI says how much of a
-- player's history was vouched for directly, and clients ask participants to
-- confirm relayed records when they can reach them (Network.lua).
local _, ns = ...
local Util, Elo, RULES = ns.Util, ns.Elo, ns.RULES

local Ledger = {}
Ledger.__index = Ledger
ns.Ledger = Ledger

Ledger.MAX_RECORDS = 20000
Ledger.MAX_PENDING_PER_SOURCE = 200

local function other(side) return side == "a" and "b" or "a" end

-- The part of a record both participants must agree on.
function Ledger.Content(r)
    return table.concat({ r.a, r.b, r.w, r.how, r.la, r.lb, r.ca or "", r.cb or "" }, "~")
end

-- Deterministic match id from the two players and both handshake nonces.
function Ledger.MatchId(nameA, nameB, nonceA, nonceB)
    if nameA > nameB then nameA, nameB, nonceA, nonceB = nameB, nameA, nonceB, nonceA end
    return Util.Id(nameA .. "|" .. nameB .. "|" .. tostring(nonceA) .. "|" .. tostring(nonceB))
end

-- Check and normalise raw fields into a record, or nil, reason.
function Ledger.Validate(f, now)
    if type(f) ~= "table" then return nil, "type" end
    local id = f.id
    if type(id) ~= "string" or not id:match("^[0-9a-z]+$") or #id ~= 12 then return nil, "id" end
    local a, b = Util.CanonName(f.a), Util.CanonName(f.b)
    if not a or not b or a == b then return nil, "names" end
    local w, how = f.w, f.how
    if w ~= "a" and w ~= "b" then return nil, "winner" end
    if how ~= "K" and how ~= "F" then return nil, "how" end
    local ts = Util.Int(f.ts, ns.SEASON_START, nil)
    if not ts then return nil, "ts" end
    if now and ts > now + RULES.MAX_FUTURE_SKEW then return nil, "future" end
    local la, lb = Util.Int(f.la, 1, 200), Util.Int(f.lb, 1, 200)
    if not la or not lb then return nil, "level" end
    if not RULES.TEST then
        if la < RULES.MIN_LEVEL or lb < RULES.MIN_LEVEL then return nil, "minlevel" end
        if math.abs(la - lb) > RULES.MAX_LEVEL_GAP then return nil, "levelgap" end
        if Ledger.Bracket(la) ~= Ledger.Bracket(lb) then return nil, "bracket" end
    end
    local ca, cb = Util.ClassToken(f.ca), Util.ClassToken(f.cb)
    -- Sorted participants; flip side-dependent fields if needed.
    if a > b then
        a, b, la, lb, ca, cb = b, a, lb, la, cb, ca
        w = other(w)
    end
    return { id = id, ts = ts, a = a, b = b, w = w, how = how, la = la, lb = lb, ca = ca, cb = cb }
end

-- Ladder bracket of a level: 10, 20, 30, 40, 50 or 60 (the cap). nil below MIN_LEVEL.
function Ledger.Bracket(level)
    level = tonumber(level)
    if not level then return nil end
    if level >= RULES.MAX_LEVEL then return RULES.MAX_LEVEL end
    if level < RULES.MIN_LEVEL then return RULES.TEST and RULES.MIN_LEVEL or nil end
    return math.floor(level / RULES.BRACKET_SIZE) * RULES.BRACKET_SIZE
end

-- Bracket a match counts in (both players share it; test mode uses the lower level).
function Ledger.MatchBracket(r)
    return Ledger.Bracket(math.min(r.la, r.lb)) or RULES.MIN_LEVEL
end

-- Wire format: M~id~ts36~a~b~w~how~la~lb~ca~cb~fa~fb
-- fa/fb: the sender claims that participant has confirmed.
function Ledger.Encode(r)
    local cf = r.cf or {}
    return table.concat({ "M", r.id, Util.Base36(r.ts), r.a, r.b, r.w, r.how, r.la, r.lb,
        r.ca or "", r.cb or "", (cf.a or 0) > 0 and "1" or "0", (cf.b or 0) > 0 and "1" or "0" }, "~")
end

function Ledger.Decode(text, now)
    if type(text) ~= "string" or #text > 255 then return nil end
    local f = Util.Split(text, "~")
    if f[1] ~= "M" or #f ~= 13 then return nil end
    local rec = Ledger.Validate({ id = f[2], ts = Util.FromBase36(f[3]), a = f[4], b = f[5], w = f[6],
        how = f[7], la = f[8], lb = f[9], ca = f[10], cb = f[11] }, now)
    if not rec then return nil end
    -- Claims are expressed for the sender's ordering, which Validate may have flipped.
    local fa, fb = f[12] == "1", f[13] == "1"
    if Util.CanonName(f[4]) ~= rec.a then fa, fb = fb, fa end
    rec.claim = { a = fa, b = fb }
    return rec
end

---------------------------------------------------------------------------
-- Ledger object over a persistent table: store[id] = record.
---------------------------------------------------------------------------
function Ledger.New(store)
    local self = setmetatable({ store = store or {}, conflicts = 0, dirty = true, rev = 1 }, Ledger)
    self.count = 0
    for _ in pairs(self.store) do self.count = self.count + 1 end
    self.pendingBySource = {}
    for _, r in pairs(self.store) do
        if r.src and Ledger.Status(r) == "pending" then
            self.pendingBySource[r.src] = (self.pendingBySource[r.src] or 0) + 1
        end
    end
    return self
end

function Ledger:Get(id) return self.store[id] end

-- rev changes whenever anything that sync or ratings depend on changes.
function Ledger:_touch()
    self.dirty = true
    self.rev = (self.rev or 0) + 1
end

function Ledger.Status(r)
    local dn = r.dn
    if dn and (dn.a or dn.b) then return "disputed" end
    local cf = r.cf or {}
    if (cf.a or 0) > 0 and (cf.b or 0) > 0 then return "verified" end
    return "pending"
end

-- How many participants confirmed straight to us (0..2).
function Ledger.DirectCount(r)
    local cf = r.cf or {}
    return ((cf.a or 0) >= 2 and 1 or 0) + ((cf.b or 0) >= 2 and 1 or 0)
end

function Ledger.SideOf(r, name)
    if name == r.a then return "a" elseif name == r.b then return "b" end
    return nil
end

-- Ingest a decoded/validated record.
--   sender: canonical name of whoever handed it to us (nil = ourselves)
--   selfName: our own name (our own attestations count as direct)
-- Returns one of: "new", "updated", "same", "conflict", "rejected".
function Ledger:Ingest(rec, sender, selfName, now)
    local senderSide = sender and Ledger.SideOf(rec, sender)
    local cur = self.store[rec.id]
    if cur then
        if Ledger.Content(cur) ~= Ledger.Content(rec) then
            -- Two versions of one match. A participant telling us a different
            -- story than the one we hold disputes it; a third party cannot.
            self.conflicts = self.conflicts + 1
            if senderSide then
                cur.dn = cur.dn or {}
                if not cur.dn[senderSide] then
                    cur.dn[senderSide] = true
                    self:_touch()
                    return "updated"
                end
            end
            return "conflict"
        end
    else
        if self.count >= Ledger.MAX_RECORDS then return "rejected" end
        local src = sender or selfName
        if not senderSide and sender then
            -- Relayed and not yet verified: cap what one source can push on us.
            local verifiedClaim = rec.claim and rec.claim.a and rec.claim.b
            if not verifiedClaim and (self.pendingBySource[src] or 0) >= Ledger.MAX_PENDING_PER_SOURCE then
                return "rejected"
            end
        end
        cur = { id = rec.id, ts = rec.ts, a = rec.a, b = rec.b, w = rec.w, how = rec.how,
            la = rec.la, lb = rec.lb, ca = rec.ca, cb = rec.cb, cf = { a = 0, b = 0 },
            src = src, seen = now }
        self.store[rec.id] = cur
        self.count = self.count + 1
        if Ledger.Status(cur) == "pending" and src then
            self.pendingBySource[src] = (self.pendingBySource[src] or 0) + 1
        end
        self:_touch()
        self:_Confirm(cur, rec, sender, senderSide, selfName)
        return "new"
    end
    local before = Ledger.Status(cur) .. (cur.cf.a or 0) .. (cur.cf.b or 0) .. cur.ts
    self:_Confirm(cur, rec, sender, senderSide, selfName)
    if rec.ts < cur.ts then cur.ts = rec.ts end  -- both attestations converge on the earliest
    local after = Ledger.Status(cur) .. (cur.cf.a or 0) .. (cur.cf.b or 0) .. cur.ts
    if before ~= after then self:_touch(); return "updated" end
    return "same"
end

function Ledger:_Confirm(cur, rec, sender, senderSide, selfName)
    local wasPending = Ledger.Status(cur) == "pending"
    local cf = cur.cf
    if sender == nil and selfName then
        -- Our own attestation.
        local side = Ledger.SideOf(cur, selfName)
        if side then cf[side] = 2 end
    elseif senderSide then
        cf[senderSide] = 2
    end
    local claim = rec.claim
    if claim then
        if claim.a and (cf.a or 0) < 1 then cf.a = 1 end
        if claim.b and (cf.b or 0) < 1 then cf.b = 1 end
    end
    if wasPending and Ledger.Status(cur) ~= "pending" and cur.src and self.pendingBySource[cur.src] then
        self.pendingBySource[cur.src] = math.max(0, self.pendingBySource[cur.src] - 1)
    end
end

-- A participant tells us directly that a match did not happen as recorded.
function Ledger:Deny(id, sender)
    local cur = self.store[id]
    if not cur then return false end
    local side = Ledger.SideOf(cur, sender)
    if not side then return false end
    cur.dn = cur.dn or {}
    if cur.dn[side] then return false end
    cur.dn[side] = true
    self:_touch()
    return true
end

-- A participant confirms directly (answer to a confirmation query).
function Ledger:ConfirmDirect(id, sender)
    local cur = self.store[id]
    if not cur then return false end
    local side = Ledger.SideOf(cur, sender)
    if not side or (cur.cf[side] or 0) >= 2 then return false end
    cur.cf[side] = 2
    self:_touch()
    return true
end

-- Ordered list of verified records.
function Ledger:Verified()
    local list = {}
    for _, r in pairs(self.store) do
        if Ledger.Status(r) == "verified" then list[#list + 1] = r end
    end
    table.sort(list, function(x, y)
        if x.ts ~= y.ts then return x.ts < y.ts end
        return x.id < y.id
    end)
    return list
end

-- Anti-farm weight for a pair given that pair's earlier counted games.
-- history: list of { ts, winnerName } for the pair, oldest first.
function Ledger.PairWeight(history, ts)
    local inDay, inWeek, inMonth = 0, 0, 0
    local wins = {}
    for i = #history, 1, -1 do
        local h = history[i]
        local age = ts - h[1]
        if age >= RULES.LOPSIDED_WINDOW then break end
        inMonth = inMonth + 1
        wins[h[2]] = (wins[h[2]] or 0) + 1
        if age < RULES.PAIR_WEEK then inWeek = inWeek + 1 end
        if age < RULES.PAIR_WINDOW then inDay = inDay + 1 end
    end
    if inWeek >= RULES.PAIR_WEEK_MAX then return 0, "week" end
    if inMonth >= RULES.LOPSIDED_MIN_GAMES then
        for _, n in pairs(wins) do
            if n / inMonth >= RULES.LOPSIDED_SHARE then return 0, "lopsided" end
        end
    end
    local w = RULES.PAIR_WEIGHTS[inDay + 1] or 0
    return w, w == 0 and "day" or nil
end

local function newPlayer(name, bracket)
    return { name = name, bracket = bracket, r = Elo.START, g = 0, counted = 0, w = 0, l = 0, peak = Elo.START,
        hist = {}, direct = 0, last = 0, opponents = {}, nOpp = 0 }
end

function Ledger.IsRanked(p)
    return p.nOpp >= RULES.MIN_OPPONENTS and p.counted >= Elo.PROVISIONAL_GAMES
end

-- Replay every verified match. Returns byBracket[bracket][name] and deltas[id].
-- player = { r, g, counted, w, l, peak, class, level, last, hist = {{ts, r, d, id}}, direct }
-- Each bracket is an independent ladder with its own ratings.
function Ledger:Derive()
    local byBracket, deltas, pairs_ = {}, {}, {}
    for _, r in ipairs(self:Verified()) do
        local br = Ledger.MatchBracket(r)
        local players = byBracket[br]
        if not players then players = {}; byBracket[br] = players end
        local pa = players[r.a] or newPlayer(r.a, br); players[r.a] = pa
        local pb = players[r.b] or newPlayer(r.b, br); players[r.b] = pb
        local key = br .. "|" .. r.a .. "|" .. r.b
        local ph = pairs_[key] or {}; pairs_[key] = ph
        local weight, why = Ledger.PairWeight(ph, r.ts)
        if r.how == "F" then weight = weight * RULES.FLED_WEIGHT end
        local sa = r.w == "a" and 1 or 0
        local da = Elo.Delta(pa.r, pa.counted, pb.r, sa, weight)
        local db = Elo.Delta(pb.r, pb.counted, pa.r, 1 - sa, weight)
        -- Beating a provisional player as an established one is worth less.
        if da > 0 and pa.counted >= Elo.PROVISIONAL_GAMES and pb.counted < Elo.PROVISIONAL_GAMES then
            da = Util.Round(da * RULES.PROVISIONAL_FARM)
        end
        if db > 0 and pb.counted >= Elo.PROVISIONAL_GAMES and pa.counted < Elo.PROVISIONAL_GAMES then
            db = Util.Round(db * RULES.PROVISIONAL_FARM)
        end
        deltas[r.id] = { ra = pa.r, rb = pb.r, da = da, db = db, weight = weight, why = why, bracket = br }
        pa.r, pb.r = pa.r + da, pb.r + db
        if weight > 0 then
            ph[#ph + 1] = { r.ts, r.w == "a" and r.a or r.b }
            pa.counted, pb.counted = pa.counted + 1, pb.counted + 1
            if not pa.opponents[r.b] then pa.opponents[r.b] = true; pa.nOpp = pa.nOpp + 1 end
            if not pb.opponents[r.a] then pb.opponents[r.a] = true; pb.nOpp = pb.nOpp + 1 end
        end
        pa.g, pb.g = pa.g + 1, pb.g + 1
        if sa == 1 then pa.w, pb.l = pa.w + 1, pb.l + 1 else pa.l, pb.w = pa.l + 1, pb.w + 1 end
        if pa.r > pa.peak then pa.peak = pa.r end
        if pb.r > pb.peak then pb.peak = pb.r end
        pa.class, pb.class = r.ca or pa.class, r.cb or pb.class
        pa.level, pb.level = r.la, r.lb
        pa.last, pb.last = r.ts, r.ts
        if (r.cf.a or 0) >= 2 then pa.direct = pa.direct + 1 end
        if (r.cf.b or 0) >= 2 then pb.direct = pb.direct + 1 end
        pa.hist[#pa.hist + 1] = { r.ts, pa.r, da, r.id }
        pb.hist[#pb.hist + 1] = { r.ts, pb.r, db, r.id }
    end
    self.dirty = false
    return byBracket, deltas
end

-- One bracket's players (tests and tools).
function Ledger:DeriveBracket(br)
    local all, deltas = self:Derive()
    return all[br] or {}, deltas
end

-- Drop the oldest pending/disputed records when over capacity.
function Ledger:Prune(now, maxAge)
    local removed = 0
    for id, r in pairs(self.store) do
        if Ledger.Status(r) ~= "verified" and now - (r.seen or r.ts) > maxAge then
            self.store[id] = nil
            removed = removed + 1
        end
    end
    self.count = self.count - removed
    if removed > 0 then self:_touch() end
    return removed
end

return Ledger
