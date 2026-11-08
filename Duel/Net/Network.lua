-- Network.lua: who we talk to and when. Routes messages, keeps peers, runs the
-- sync engine, announces our inventory, and asks participants to vouch for
-- matches we only heard about second-hand.
--
-- Message kinds (prefix "DuelLadder"):
--   H / R / L           ranked handshake (Agreement.lua), whisper only
--   M                   match record / attestation (Ledger.lua)
--   SI SD SB SBE SL SLI SLE SG   anti-entropy (SyncEngine.lua)
--   CQ~id:ts,id:ts,...  "did these matches of yours happen?"  (to a participant; ts base36)
--   CA~id:1,id:0,...    answers: 1 confirmed, 0 denied, ? unknown
--   DN~id~name          hint: that participant denied this match to me (we re-ask them)
local _, ns = ...
local Util, Ledger, Proto = ns.Util, ns.Ledger, ns.SyncProto

local N = { routes = {}, lastInvTo = {}, cq = {}, cqTried = {}, unreachable = {} }
ns.Network = N

N.PEER_KEEP = 30 * 86400
N.INV_REPLY_GAP = 120          -- answer one peer's inventory with ours at most this often
N.GUILD_INV_EVERY = 600
N.ROTATE_EVERY = 90            -- whisper our inventory to one known peer
N.GREET_EVERY = 75             -- greet one directory name we have not heard from
N.CQ_EVERY = 4                 -- one confirmation query per this many seconds
N.CQ_MAX_IDS = 18
N.UNREACHABLE_FOR = 1800

local function now() return GetTime() end

local function serverNow() return GetServerTime and GetServerTime() or time() end

-- Remember how to reach a player.
local function noteRoute(name, channel, bnetId)
    if channel == "BNET" and bnetId then
        N.routes[name] = { kind = "BNET", id = bnetId }
    elseif not N.routes[name] or N.routes[name].kind ~= "BNET" then
        N.routes[name] = { kind = "WHISPER" }
    end
    local p = ns.db.peers[name] or {}
    p.seen = serverNow()
    ns.db.peers[name] = p
    N.unreachable[name] = nil
end

function N.SendTo(name, msg, urgent)
    local route = N.routes[name]
    if route and route.kind == "BNET" then
        return ns.Transport.Send(msg, "BNET", route.id, urgent)
    end
    return ns.Transport.Send(msg, "WHISPER", name, urgent)
end

function N.Broadcast(msg)
    if IsInRaid() then ns.Transport.Send(msg, "RAID")
    elseif IsInGroup() then ns.Transport.Send(msg, "PARTY") end
    if ns.db.settings.guildShare and IsInGuild() then ns.Transport.Send(msg, "GUILD") end
end

---------------------------------------------------------------------------
-- Confirmation queries
---------------------------------------------------------------------------
local function wantConfirm(rec, name)
    if not name or name == ns.me.name or N.unreachable[name] then return end
    local key = rec.id .. name
    if (N.cqTried[key] or 0) >= 2 then return end
    local list = N.cq[name]
    if not list then list = {}; N.cq[name] = list end
    for _, id in ipairs(list) do if id == rec.id then return end end
    if #list < 200 then list[#list + 1] = rec.id end
end

function N.QueueConfirmations(rec)
    local r = ns.ledger:Get(rec.id)
    if not r then return end
    if (r.cf.a or 0) < 2 then wantConfirm(r, r.a) end
    if (r.cf.b or 0) < 2 then wantConfirm(r, r.b) end
end

local function sendOneCQ()
    for name, ids in pairs(N.cq) do
        if N.unreachable[name] then
            N.cq[name] = nil
        elseif #ids > 0 then
            local batch = {}
            while #ids > 0 and #batch < N.CQ_MAX_IDS do
                local id = table.remove(ids)
                local r = ns.ledger:Get(id)
                if r then
                    batch[#batch + 1] = id .. ":" .. Util.Base36(r.ts)
                    N.cqTried[id .. name] = (N.cqTried[id .. name] or 0) + 1
                end
            end
            if #ids == 0 then N.cq[name] = nil end
            if #batch > 0 then N.SendTo(name, "CQ~" .. table.concat(batch, ",")) end
            return
        else
            N.cq[name] = nil
        end
    end
end

-- Someone asks whether matches involving us happened.
local function answerCQ(sender, body)
    local out = {}
    -- Only this continuous session is certain: SavedVariables are written at logout,
    -- so a crash or another PC can lose older attestations. Denying those could
    -- dispute real matches; we answer "unknown" for them instead.
    local since = ns.sessionStart or serverNow()
    for _, item in ipairs(Util.Split(body, ",")) do
        local id, ts36 = item:match("^([0-9a-z]+):([0-9a-z]+)$")
        local ts = ts36 and Util.FromBase36(ts36)
        if id and #id == 12 and ts and #out < N.CQ_MAX_IDS then
            local r = ns.ledger:Get(id)
            local side = r and Ledger.SideOf(r, ns.me.name)
            local answer
            if r and side and (r.cf[side] or 0) >= 2 then
                answer = "1"
            elseif r and not side then
                answer = "0"   -- we are not even in it
            elseif ts >= since then
                -- We were online with Duel running, and never attested it.
                answer = "0"
            else
                answer = "?"
            end
            out[#out + 1] = id .. ":" .. answer
        end
    end
    if #out > 0 then N.SendTo(sender, "CA~" .. table.concat(out, ",")) end
end

local function onCA(sender, body)
    local changed = false
    for _, item in ipairs(Util.Split(body, ",")) do
        local id, a = item:match("^([0-9a-z]+):([01%?])$")
        if id then
            if a == "1" then
                changed = ns.ledger:ConfirmDirect(id, sender) or changed
            elseif a == "0" then
                if ns.ledger:Deny(id, sender) then
                    changed = true
                    N.Broadcast("DN~" .. id .. "~" .. sender)
                end
            end
        end
    end
    if changed then ns.OnLedgerChanged() end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function onMessage(text, channel, sender, bnetId)
    noteRoute(sender, channel, bnetId)
    local kind = text:match("^(%u+)")
    if not kind then return end

    if kind == "H" or kind == "R" or kind == "L" then
        if channel == "WHISPER" or channel == "BNET" then
            ns.Controller.OnHandshake(sender, text)
        end
        return
    end
    if kind == "CQ" then return answerCQ(sender, text:sub(4)) end
    if kind == "CA" then return onCA(sender, text:sub(4)) end
    if kind == "DN" then
        local id, who = text:match("^DN~([0-9a-z]+)~(.+)$")
        local r = id and ns.ledger:Get(id)
        who = Util.CanonName(who)
        if r and who and Ledger.SideOf(r, who) and not (r.dn and r.dn[Ledger.SideOf(r, who)]) then
            N.cqTried[id .. who] = nil
            wantConfirm(r, who)
        end
        return
    end

    if kind == "SI" then
        local inv = Proto.DecodeInventory(text)
        if inv then
            local p = ns.db.peers[sender]
            p.version = inv.version or p.version
            if inv.version then ns.NoteVersion(inv.version) end
            if inv.proto ~= ns.PROTO then return end
        end
    end

    local status = ns.sync:OnMessage(sender, text)
    if kind == "SI" and status and status ~= "ignored" then
        -- Let them pull from us too (they may hold less than we do).
        local last = N.lastInvTo[sender] or -1000
        if status ~= "same" and now() - last > N.INV_REPLY_GAP then
            N.lastInvTo[sender] = now()
            N.SendTo(sender, ns.sync:InventoryLine())
        end
    end
end

---------------------------------------------------------------------------
-- Schedules
---------------------------------------------------------------------------
local function knownPeers(maxAge)
    local list, t = {}, serverNow()
    for name, p in pairs(ns.db.peers) do
        if t - (p.seen or 0) < maxAge and not N.unreachable[name] then list[#list + 1] = name end
    end
    return list
end

function N.Announce()
    N.Broadcast(ns.sync:InventoryLine())
    N.lastGuildInv = now()
end

-- Forever friends on Battle.net running Duel get our inventory (they answer if they run it).
local function greetBNetFriends()
    if not ns.db.settings.bnet or not (C_BattleNet and BNGetNumFriends) then return end
    local sent = 0
    for i = 1, BNGetNumFriends() do
        local n = C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(i) or 0
        for j = 1, n do
            local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if g and g.clientProgram == "WoW" and g.isOnline and g.gameAccountID
                and (g.wowProjectID == 18 or g.wowProjectID == WOW_PROJECT_ID) and sent < 10 then
                ns.Transport.Send(ns.sync:InventoryLine(), "BNET", g.gameAccountID)
                sent = sent + 1
            end
        end
    end
end

local function rotate()
    if InCombatLockdown() then return end
    -- One known peer, so ladders keep converging without any broadcast.
    local list = knownPeers(3600 * 6)
    if #list > 0 then
        local name = list[math.random(1, #list)]
        N.lastInvTo[name] = now()
        N.SendTo(name, ns.sync:InventoryLine())
    end
end

local function greet()
    if InCombatLockdown() or not ns.Directory then return end
    local active = #knownPeers(1800)
    if active >= 8 then return end
    local name = ns.Directory.Candidate(function(n)
        return ns.db.peers[n] ~= nil or N.unreachable[n] ~= nil
    end)
    if name then
        ns.Directory.stats.greeted = ns.Directory.stats.greeted + 1
        N.lastInvTo[name] = now()
        N.SendTo(name, ns.sync:InventoryLine())
    end
end

function N.Start()
    table.insert(ns.Transport.handlers, onMessage)
    ns.Transport.onUnreachable = function(name)
        N.unreachable[name] = now()
        N.cq[name] = nil
    end
    C_Timer.After(15 + math.random() * 10, function()
        N.Announce()
        greetBNetFriends()
    end)
    C_Timer.NewTicker(N.GUILD_INV_EVERY, function()
        if not InCombatLockdown() then N.Announce() end
    end)
    C_Timer.NewTicker(N.ROTATE_EVERY, rotate)
    C_Timer.NewTicker(N.GREET_EVERY, greet)
    C_Timer.NewTicker(N.CQ_EVERY, function()
        if not InCombatLockdown() then sendOneCQ() end
    end)
    C_Timer.NewTicker(300, function()
        local t = now()
        for name, at in pairs(N.unreachable) do
            if t - at > N.UNREACHABLE_FOR then N.unreachable[name] = nil end
        end
    end)
    local f = CreateFrame("Frame")
    pcall(f.RegisterEvent, f, "GROUP_JOINED")
    f:SetScript("OnEvent", function() C_Timer.After(3, function()
        if IsInGroup() then ns.Transport.Send(ns.sync:InventoryLine(), IsInRaid() and "RAID" or "PARTY") end
    end) end)
end

function N.PeerCount(maxAge) return #knownPeers(maxAge or 1800) end

return N
