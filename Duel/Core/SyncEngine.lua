-- SyncEngine.lua: runs the SyncProto conversation with each peer. Pure logic:
-- deps.send(peer, line) is the only way out, so tests can connect two engines.
--
-- Either side may start a session after hearing an inventory (SI) that differs
-- from its own. The requester drives; the responder only answers requests and is
-- stateless apart from rate limits. Every reply is bounded.
local _, ns = ...
local Util, Ledger, Proto = ns.Util, ns.Ledger, ns.SyncProto

local Engine = {}
Engine.__index = Engine
ns.SyncEngine = Engine

Engine.SESSION_TIMEOUT = 90     -- a session that stops making progress is dropped
Engine.RESYNC_COOLDOWN = 45     -- min seconds between sessions with one peer
Engine.BUCKETS_COOLDOWN = 20    -- answer one peer's SD at most this often
Engine.MAX_DAYS = 12            -- days examined per session
Engine.MAX_SEND = 250           -- records we send one peer per session window
Engine.MAX_RECV = 400           -- records we accept from one peer per session window
Engine.SEND_WINDOW = 300

-- deps: ledger, send(peer, line), now(), selfName(), serverNow() optional,
--       onIngest(result, rec, peer) optional
function Engine.New(deps)
    return setmetatable({ deps = deps, sessions = {}, peers = {}, cache = nil }, Engine)
end

function Engine:Summary()
    local led = self.deps.ledger
    if not self.cache or self.cache.rev ~= led.rev then
        self.cache = { rev = led.rev, sum = Proto.Summarize(led.store) }
    end
    return self.cache.sum
end

function Engine:InventoryLine() return Proto.EncodeInventory(self:Summary()) end

function Engine:_peer(name)
    local p = self.peers[name]
    local now = self.deps.now()
    if not p then
        p = { sent = 0, recv = 0, windowAt = now }
        self.peers[name] = p
    end
    if now - p.windowAt > Engine.SEND_WINDOW then p.sent, p.recv, p.windowAt = 0, 0, now end
    return p
end

function Engine:Active(peer)
    local s = self.sessions[peer]
    if s and self.deps.now() - s.touched > Engine.SESSION_TIMEOUT then
        self.sessions[peer] = nil
        s = nil
    end
    return s
end

-- Start pulling from a peer whose inventory differs. Returns true if started.
function Engine:Start(peer, force)
    if self:Active(peer) then return false end
    local p = self:_peer(peer)
    local now = self.deps.now()
    if not force and p.lastSession and now - p.lastSession < Engine.RESYNC_COOLDOWN then return false end
    p.lastSession = now
    self.sessions[peer] = { phase = "buckets", theirs = {}, days = {}, ids = {}, touched = now }
    self.deps.send(peer, "SD")
    return true
end

function Engine:_sendRecord(peer, id)
    local r = self.deps.ledger:Get(id)
    if not r then return false end
    local p = self:_peer(peer)
    if p.sent >= Engine.MAX_SEND then return false end
    p.sent = p.sent + 1
    self.deps.send(peer, Ledger.Encode(r))
    return true
end

function Engine:_dayFlags(day)
    local out = {}
    local b = self:Summary().days[day]
    if b then
        for _, item in ipairs(b.ids) do out[item:sub(1, 12)] = tonumber(item:sub(13)) end
    end
    return out
end

function Engine:_finishDay(peer, s, day)
    local theirs = s.ids[day] or {}
    local mine = self:_dayFlags(day)
    for _, line in ipairs(Proto.EncodeGets(Proto.Wanted(mine, theirs))) do self.deps.send(peer, line) end
    for _, id in ipairs(Proto.Offer(mine, theirs)) do
        if not self:_sendRecord(peer, id) then break end
    end
    s.days[day], s.ids[day] = nil, nil
    if next(s.days) == nil then
        self.sessions[peer] = nil
        s.done = true
    end
end

-- Handle one sync line. Returns a status string, or nil if the line is not ours.
function Engine:OnMessage(peer, text)
    local kind = text:match("^(%u+)")
    local now = self.deps.now()
    if kind == "SI" then
        local inv = Proto.DecodeInventory(text)
        if not inv or inv.proto ~= ns.PROTO then return "ignored" end
        local p = self:_peer(peer)
        p.inventory, p.heardAt = inv, now
        if Proto.Same(inv, self:Summary()) then
            p.inSync = true
            return "same"
        end
        p.inSync = false
        return self:Start(peer) and "started" or "differs"
    elseif kind == "SD" then
        local p = self:_peer(peer)
        if p.bucketsAt and now - p.bucketsAt < Engine.BUCKETS_COOLDOWN then return "limited" end
        p.bucketsAt = now
        for _, line in ipairs(Proto.EncodeBuckets(self:Summary())) do self.deps.send(peer, line) end
        return "buckets"
    elseif kind == "SB" then
        local s = self:Active(peer)
        if s and s.phase == "buckets" then
            Proto.DecodeBuckets(text, s.theirs)
            s.touched = now
        end
        return "bucket"
    elseif kind == "SBE" then
        local s = self:Active(peer)
        if not s or s.phase ~= "buckets" then return "ignored" end
        s.phase, s.touched = "ids", now
        local mine = self:Summary()
        local n = 0
        for _, d in ipairs(Proto.DiffDays(mine, s.theirs)) do
            if n >= Engine.MAX_DAYS then break end
            n = n + 1
            s.days[d] = true
            self.deps.send(peer, "SL~" .. Util.Base36(d))
        end
        -- Days the peer has nothing for: push what we hold.
        for _, d in ipairs(Proto.DaysTheyLack(mine, s.theirs)) do
            for _, item in ipairs(mine.days[d].ids) do
                if not self:_sendRecord(peer, item:sub(1, 12)) then break end
            end
        end
        if n == 0 then self.sessions[peer] = nil end
        return "diffed"
    elseif kind == "SL" then
        local d = Util.FromBase36(text:match("^SL~([0-9a-z]+)$") or "")
        if not d then return "ignored" end
        local b = self:Summary().days[d]
        for _, line in ipairs(Proto.EncodeIds(d, b and b.ids or {})) do self.deps.send(peer, line) end
        return "ids"
    elseif kind == "SLI" then
        local s = self:Active(peer)
        local d, ids = Proto.DecodeIds(text)
        if s and d and s.days[d] then
            local acc = s.ids[d] or {}
            s.ids[d] = acc
            for id, fl in pairs(ids) do acc[id] = fl end
            s.touched = now
        end
        return "idlist"
    elseif kind == "SLE" then
        local s = self:Active(peer)
        local d = Util.FromBase36(text:match("^SLE~([0-9a-z]+)$") or "")
        if s and d and s.days[d] then
            s.touched = now
            self:_finishDay(peer, s, d)
        end
        return "dayend"
    elseif kind == "SG" then
        local ids = Proto.DecodeGets(text)
        if not ids then return "ignored" end
        for _, id in ipairs(ids) do
            if not self:_sendRecord(peer, id) then break end
        end
        return "records"
    elseif kind == "M" then
        local p = self:_peer(peer)
        if p.recv >= Engine.MAX_RECV then return "limited" end
        p.recv = p.recv + 1
        local t = self.deps.serverNow and self.deps.serverNow() or nil
        local rec = Ledger.Decode(text, t)
        if not rec then return "invalid" end
        local s = self:Active(peer)
        if s then s.touched = now end
        local result = self.deps.ledger:Ingest(rec, peer, self.deps.selfName(), t or now)
        if self.deps.onIngest then self.deps.onIngest(result, rec, peer) end
        return result
    end
    return nil
end

return Engine
