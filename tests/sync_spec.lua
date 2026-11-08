local ns = load_ns()
local Ledger, Util, SyncEngine = ns.Ledger, ns.Util, ns.SyncEngine
local T0 = ns.SEASON_START + 86400 * 10

-- A small network of nodes exchanging lines through a shared queue.
local function network(names)
    local clock = new_clock()
    local queue, nodes = {}, {}
    for _, name in ipairs(names) do
        local led = Ledger.New({})
        local node = { name = name, ledger = led, sent = 0 }
        node.engine = SyncEngine.New({
            ledger = led, now = clock.now, selfName = function() return name end,
            serverNow = function() return T0 + 86400 * 30 end,
            send = function(peer, line)
                ok(#line <= 255, "line too long: " .. #line)
                node.sent = node.sent + 1
                queue[#queue + 1] = { from = name, to = peer, line = line }
            end,
        })
        nodes[name] = node
    end
    local function pump(maxSteps, drop)
        local steps = 0
        while #queue > 0 and steps < (maxSteps or 100000) do
            steps = steps + 1
            local m = table.remove(queue, 1)
            if not (drop and drop(m)) then nodes[m.to].engine:OnMessage(m.from, m.line) end
        end
        return steps
    end
    -- Announce inventories both ways.
    local function hello(a, b)
        nodes[b].engine:OnMessage(a, nodes[a].engine:InventoryLine())
        nodes[a].engine:OnMessage(b, nodes[b].engine:InventoryLine())
    end
    return nodes, pump, hello, clock
end

local function addMatch(node, i, a, b, day, selfConfirm, claimA, claimB)
    local r = Ledger.Validate({ id = Util.Id("match" .. i), ts = T0 + day * 86400 + i, a = a, b = b,
        w = (i % 2 == 0) and "a" or "b", how = "K", la = 60, lb = 60, ca = "WARRIOR", cb = "PRIEST" })
    r.claim = { a = claimA ~= false, b = claimB ~= false }
    node.ledger:Ingest(r, nil, selfConfirm and node.name or "Nobody Here", T0)
    return r.id
end

local function ratings(node)
    local out = {}
    for name, p in pairs(node.ledger:Derive()) do out[name] = p.r end
    return out
end

test("two peers with disjoint ledgers converge", function()
    local nodes, pump, hello = network({ "Alice Stone", "Bob Marsh" })
    for i = 1, 30 do addMatch(nodes["Alice Stone"], i, "Carl Third", "Dora Fourth", i % 5) end
    for i = 31, 45 do addMatch(nodes["Bob Marsh"], i, "Erin Fifth", "Carl Third", i % 7) end
    hello("Alice Stone", "Bob Marsh"); pump()
    eq(nodes["Alice Stone"].ledger.count, 45)
    eq(nodes["Bob Marsh"].ledger.count, 45)
    eq(ratings(nodes["Alice Stone"]), ratings(nodes["Bob Marsh"]))
    local s1, s2 = nodes["Alice Stone"].engine:Summary(), nodes["Bob Marsh"].engine:Summary()
    ok(ns.SyncProto.Same(s1, s2), "inventories equal")
end)

test("in-sync peers exchange only inventories", function()
    local nodes, pump, hello = network({ "Alice Stone", "Bob Marsh" })
    for i = 1, 5 do
        addMatch(nodes["Alice Stone"], i, "Carl Third", "Dora Fourth", 1)
        addMatch(nodes["Bob Marsh"], i, "Carl Third", "Dora Fourth", 1)
    end
    hello("Alice Stone", "Bob Marsh")
    eq(pump(), 0)
end)

test("a newly verified record propagates its new confirmation", function()
    local nodes, pump, hello, clock = network({ "Alice Stone", "Bob Marsh" })
    -- Alice holds a pending record (only her own side), Bob the same id verified.
    local r = Ledger.Validate({ id = Util.Id("m1"), ts = T0, a = "Alice Stone", b = "Carl Third", w = "a",
        how = "K", la = 60, lb = 60 })
    r.claim = { a = true, b = false }
    nodes["Alice Stone"].ledger:Ingest(r, nil, "Alice Stone", T0)
    hello("Alice Stone", "Bob Marsh"); pump()
    eq(Ledger.Status(nodes["Bob Marsh"].ledger:Get(r.id)), "pending")
    -- Carl confirms to Bob directly.
    local r2 = Ledger.Validate(r); r2.claim = { a = true, b = true }
    nodes["Bob Marsh"].ledger:Ingest(r2, "Carl Third", "Bob Marsh", T0)
    clock.advance(SyncEngine.RESYNC_COOLDOWN + 1)
    hello("Alice Stone", "Bob Marsh"); pump()
    eq(Ledger.Status(nodes["Alice Stone"].ledger:Get(r.id)), "verified")
end)

test("three peers converge through a middle node (gossip)", function()
    local nodes, pump, hello, clock = network({ "Alice Stone", "Bob Marsh", "Carl Third" })
    for i = 1, 10 do addMatch(nodes["Alice Stone"], i, "Xan One", "Yul Two", i % 3) end
    for i = 11, 20 do addMatch(nodes["Carl Third"], i, "Xan One", "Zed Three", i % 4) end
    hello("Alice Stone", "Bob Marsh"); pump()
    hello("Carl Third", "Bob Marsh"); pump()
    clock.advance(SyncEngine.RESYNC_COOLDOWN + 1)
    hello("Alice Stone", "Bob Marsh"); pump()
    for _, n in pairs(nodes) do eq(n.ledger.count, 20, n.name) end
    eq(ratings(nodes["Alice Stone"]), ratings(nodes["Carl Third"]))
end)

test("lost messages: a later session recovers", function()
    local nodes, pump, hello, clock = network({ "Alice Stone", "Bob Marsh" })
    for i = 1, 25 do addMatch(nodes["Alice Stone"], i, "Carl Third", "Dora Fourth", i % 6) end
    local n = 0
    hello("Alice Stone", "Bob Marsh"); pump(nil, function() n = n + 1; return n % 3 == 0 end)
    ok(nodes["Bob Marsh"].ledger.count < 25, "partial")
    for _ = 1, 6 do
        clock.advance(SyncEngine.SESSION_TIMEOUT + 1)
        hello("Alice Stone", "Bob Marsh"); pump()
    end
    eq(nodes["Bob Marsh"].ledger.count, 25)
end)

test("duplicate deliveries are harmless", function()
    local nodes, pump, hello = network({ "Alice Stone", "Bob Marsh" })
    local id = addMatch(nodes["Alice Stone"], 1, "Carl Third", "Dora Fourth", 1)
    local line = Ledger.Encode(nodes["Alice Stone"].ledger:Get(id))
    for _ = 1, 5 do nodes["Bob Marsh"].engine:OnMessage("Alice Stone", line) end
    eq(nodes["Bob Marsh"].ledger.count, 1)
end)

test("garbage lines are rejected", function()
    local nodes = network({ "Alice Stone" })
    local e = nodes["Alice Stone"].engine
    eq(e:OnMessage("Bob Marsh", "M~bad"), "invalid")
    eq(e:OnMessage("Bob Marsh", "SI~1~x~y"), "ignored")
    eq(e:OnMessage("Bob Marsh", "SG~" .. string.rep("a", 300)), "records")
    eq(e:OnMessage("Bob Marsh", "SL~"), "ignored")
    eq(nodes["Alice Stone"].ledger.count, 0)
end)

test("a forged conflicting version from a relay does not overwrite", function()
    local nodes = network({ "Alice Stone" })
    local id = addMatch(nodes["Alice Stone"], 1, "Carl Third", "Dora Fourth", 1)
    local r = nodes["Alice Stone"].ledger:Get(id)
    local forged = Ledger.Encode(r):gsub("~K~", "~F~")
    eq(nodes["Alice Stone"].engine:OnMessage("Mallory Evil", forged), "conflict")
    eq(nodes["Alice Stone"].ledger:Get(id).how, "K")
end)
