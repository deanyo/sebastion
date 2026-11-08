local ns = load_ns()
local Ledger, Util = ns.Ledger, ns.Util
local T0 = ns.SEASON_START + 86400 * 3

local function raw(over)
    local r = { id = Ledger.MatchId("Alice Stone", "Bob Marsh", "n1", "n2"), ts = T0,
        a = "Alice Stone", b = "Bob Marsh", w = "a", how = "K", la = 60, lb = 60, ca = "MAGE", cb = "ROGUE" }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

local function attest(led, r, sender, claimA, claimB, me)
    local rec = Ledger.Validate(r)
    rec.claim = { a = claimA, b = claimB }
    return led:Ingest(rec, sender, me, T0)
end

test("validate sorts participants and flips the winner", function()
    local v = Ledger.Validate(raw({ a = "Bob Marsh", b = "Alice Stone", w = "b", ca = "ROGUE", cb = "MAGE" }))
    eq(v.a, "Alice Stone"); eq(v.w, "a"); eq(v.ca, "MAGE"); eq(v.cb, "ROGUE")
end)

test("validate rejects bad input", function()
    ok(not Ledger.Validate(raw({ a = "Bob Marsh" })), "same names")
    ok(not Ledger.Validate(raw({ la = 59 })), "level gap")
    ok(not Ledger.Validate(raw({ la = 5, lb = 5 })), "min level")
    ok(not Ledger.Validate(raw({ la = 9, lb = 9 })), "below level 10")
    ok(not Ledger.Validate(raw({ ts = ns.SEASON_START - 1 })), "pre-season")
    ok(not Ledger.Validate(raw({ ts = T0 + 1000 }), T0), "future")
    ok(not Ledger.Validate(raw({ w = "x" })), "winner")
    ok(not Ledger.Validate(raw({ id = "short" })), "id")
    ok(not Ledger.Validate(raw({ a = "Evil~Name" })), "separator in name")
end)

test("match id is the same from both sides", function()
    eq(Ledger.MatchId("Alice Stone", "Bob Marsh", "x", "y"), Ledger.MatchId("Bob Marsh", "Alice Stone", "y", "x"))
    ok(Ledger.MatchId("Alice Stone", "Bob Marsh", "x", "y") ~= Ledger.MatchId("Alice Stone", "Bob Marsh", "y", "x"))
end)

test("encode/decode roundtrip keeps claims", function()
    local led = Ledger.New({})
    attest(led, raw(), nil, false, false, "Alice Stone")
    local r = led:Get(raw().id)
    eq(r.cf.a, 2); eq(r.cf.b, 0)
    local line = Ledger.Encode(r)
    ok(#line <= 255)
    local d = Ledger.Decode(line, T0)
    eq(d.a, "Alice Stone"); eq(d.claim.a, true); eq(d.claim.b, false); eq(d.ts, T0)
end)

test("both direct attestations verify; one is pending", function()
    local led = Ledger.New({})
    eq(attest(led, raw(), nil, false, false, "Alice Stone"), "new")
    eq(Ledger.Status(led:Get(raw().id)), "pending")
    eq(attest(led, raw(), "Bob Marsh", false, true, "Alice Stone"), "updated")
    local r = led:Get(raw().id)
    eq(Ledger.Status(r), "verified"); eq(Ledger.DirectCount(r), 2)
end)

test("duplicate attestations are idempotent", function()
    local led = Ledger.New({})
    attest(led, raw(), "Bob Marsh", true, true, "Carl Third")
    eq(attest(led, raw(), "Bob Marsh", true, true, "Carl Third"), "same")
    eq(led.count, 1)
end)

test("relayed claims verify but are not direct", function()
    local led = Ledger.New({})
    attest(led, raw(), "Carl Third", true, true, "Dora Fourth")
    local r = led:Get(raw().id)
    eq(Ledger.Status(r), "verified"); eq(Ledger.DirectCount(r), 0)
    ok(led:ConfirmDirect(r.id, "Alice Stone")); eq(Ledger.DirectCount(r), 1)
    ok(not led:ConfirmDirect(r.id, "Carl Third"), "non-participant cannot confirm")
end)

test("a participant reporting a different winner disputes the match", function()
    local led = Ledger.New({})
    attest(led, raw(), nil, true, false, "Alice Stone")
    eq(attest(led, raw({ w = "b" }), "Bob Marsh", false, true, "Alice Stone"), "updated")
    eq(Ledger.Status(led:Get(raw().id)), "disputed")
end)

test("a third party's conflicting version is ignored", function()
    local led = Ledger.New({})
    attest(led, raw(), "Alice Stone", true, true, "Dora Fourth")
    eq(attest(led, raw({ w = "b" }), "Carl Third", true, true, "Dora Fourth"), "conflict")
    eq(Ledger.Status(led:Get(raw().id)), "verified")
    eq(led.conflicts, 1)
end)

test("deny only from participants", function()
    local led = Ledger.New({})
    attest(led, raw(), "Carl Third", true, true, "Dora Fourth")
    ok(not led:Deny(raw().id, "Carl Third"))
    ok(led:Deny(raw().id, "Bob Marsh"))
    eq(Ledger.Status(led:Get(raw().id)), "disputed")
end)

test("timestamps converge on the earliest attestation", function()
    local led = Ledger.New({})
    attest(led, raw({ ts = T0 + 2 }), nil, true, false, "Alice Stone")
    attest(led, raw({ ts = T0 }), "Bob Marsh", false, true, "Alice Stone")
    eq(led:Get(raw().id).ts, T0)
end)

test("one relayer cannot flood pending records", function()
    local led = Ledger.New({})
    local n = 0
    for i = 1, Ledger.MAX_PENDING_PER_SOURCE + 20 do
        local r = raw({ id = Util.Id("x" .. i) })
        if attest(led, r, "Spam Bot", true, false, "Dora Fourth") == "new" then n = n + 1 end
    end
    eq(n, Ledger.MAX_PENDING_PER_SOURCE)
end)

local function verified(led, i, winner, ts, a, b)
    local r = raw({ id = Util.Id("m" .. i), w = winner, ts = ts, a = a or "Alice Stone", b = b or "Bob Marsh" })
    attest(led, r, "Carl Third", true, true, "Dora Fourth")
    return r
end

test("derive replays verified matches deterministically", function()
    local led = Ledger.New({})
    verified(led, 1, "a", T0)
    verified(led, 2, "b", T0 + 90000)
    local players, deltas = led:DeriveBracket(60)
    local a, b = players["Alice Stone"], players["Bob Marsh"]
    eq(a.w, 1); eq(a.l, 1); eq(b.w, 1)
    eq(a.r, 1498)  -- 1520 vs 1480, then loses: round(40 * (0 - 0.5575)) = -22
end)

test("derive: exact numbers", function()
    local led = Ledger.New({})
    verified(led, 1, "a", T0)
    local players, deltas = led:DeriveBracket(60)
    eq(players["Alice Stone"].r, 1520); eq(players["Bob Marsh"].r, 1480)
    eq(players["Alice Stone"].peak, 1520); eq(players["Bob Marsh"].peak, 1500)
    local d = deltas[Util.Id("m1")]
    eq(d.da, 20); eq(d.db, -20); eq(d.ra, 1500)
end)

test("derive is independent of insertion order", function()
    local function build(order)
        local led = Ledger.New({})
        for _, i in ipairs(order) do
            verified(led, i, (i % 2 == 0) and "a" or "b", T0 + i * 100000,
                (i % 3 == 0) and "Carl Third" or "Alice Stone", "Bob Marsh")
        end
        local p = led:DeriveBracket(60)
        local out = {}
        for name, pl in pairs(p) do out[name] = pl.r end
        return out
    end
    eq(build({ 1, 2, 3, 4, 5, 6 }), build({ 6, 3, 1, 5, 2, 4 }))
end)

local function weights(led, n, prefix)
    local _, deltas = led:DeriveBracket(60)
    local out = {}
    for i = 1, n do out[i] = deltas[Util.Id((prefix or "m") .. i)].weight end
    return out
end

test("repeat opponent weights within 24h: 1, 0.5, 0.25, then 0", function()
    local led = Ledger.New({})
    for i = 1, 5 do verified(led, i, (i % 2 == 0) and "a" or "b", T0 + i * 60) end
    eq(weights(led, 5), { 1, 0.5, 0.25, 0, 0 })
end)

test("weekly cap per pair", function()
    local led = Ledger.New({})
    -- one game a day, alternating winners: 6 count in a week, the 7th does not
    for i = 1, 8 do verified(led, i, (i % 2 == 0) and "a" or "b", T0 + i * 86400 + 1) end
    eq(weights(led, 8), { 1, 1, 1, 1, 1, 1, 0, 1 })
end)

test("lopsided pair stops counting (win trading)", function()
    local led = Ledger.New({})
    -- Bob feeds Alice one loss every 2 days: after 6 counted one-sided games, nothing counts.
    for i = 1, 9 do verified(led, i, "a", T0 + i * 2 * 86400) end
    local w = weights(led, 9)
    eq(w[6], 1); eq(w[7], 0); eq(w[9], 0)
    local p = led:DeriveBracket(60)
    eq(p["Alice Stone"].counted, 6)
end)

test("fled results count half", function()
    local led = Ledger.New({})
    local r = raw({ id = Util.Id("f1"), how = "F" })
    attest(led, r, "Carl Third", true, true, "Dora Fourth")
    local p, d = led:DeriveBracket(60)
    eq(d[Util.Id("f1")].weight, 0.5)
    eq(p["Alice Stone"].r, 1510)
end)

test("established player farming a provisional alt gains half", function()
    local led = Ledger.New({})
    -- Alice gets established against 10 different opponents.
    for i = 1, 10 do verified(led, i, "a", T0 + i * 100, "Alice Stone", "Opp" .. string.char(96 + i) .. " Foe") end
    local before = led:DeriveBracket(60)["Alice Stone"]
    eq(before.counted, 10)
    verified(led, 99, "a", T0 + 5000, "Alice Stone", "Zed Freshalt")
    local p, d = led:DeriveBracket(60)
    local full = ns.Elo.Delta(before.r, 10, 1500, 1)
    eq(d[Util.Id("m99")].da, Util.Round(full * 0.5))
end)

test("ranked listing needs 5 distinct opponents and 10 games", function()
    local led = Ledger.New({})
    for i = 1, 10 do verified(led, i, "a", T0 + i * 86400 * 3) end
    local p = led:DeriveBracket(60)
    ok(not Ledger.IsRanked(p["Alice Stone"]))
    local led2 = Ledger.New({})
    for i = 1, 10 do verified(led2, i, "a", T0 + i * 100, "Alice Stone", "Opp" .. string.char(96 + (i % 5) + 1) .. " Foe") end
    ok(Ledger.IsRanked(led2:DeriveBracket(60)["Alice Stone"]))
end)

test("disputed and pending matches do not move ratings", function()
    local led = Ledger.New({})
    verified(led, 1, "a", T0)
    led:Deny(Util.Id("m1"), "Bob Marsh")
    attest(led, raw({ id = Util.Id("p1") }), nil, false, false, "Alice Stone")
    local players = led:DeriveBracket(60)
    eq(players["Alice Stone"], nil)
end)


test("brackets: same bracket and within 2 levels", function()
    ok(Ledger.Validate(raw({ la = 25, lb = 27 })), "25 vs 27")
    ok(not Ledger.Validate(raw({ la = 25, lb = 28 })), "gap 3")
    ok(not Ledger.Validate(raw({ la = 29, lb = 30 })), "across brackets")
    ok(not Ledger.Validate(raw({ la = 59, lb = 60 })), "59 vs the cap")
    ok(Ledger.Validate(raw({ la = 59, lb = 58 })), "50s bracket")
    eq(Ledger.Bracket(10), 10); eq(Ledger.Bracket(19), 10); eq(Ledger.Bracket(59), 50); eq(Ledger.Bracket(60), 60)
    eq(Ledger.Bracket(9), nil)
end)

test("brackets are independent ladders", function()
    local led = Ledger.New({})
    attest(led, raw({ id = Util.Id("lo"), la = 25, lb = 25 }), "Carl Third", true, true, "Dora Fourth")
    attest(led, raw({ id = Util.Id("hi"), w = "b", ts = T0 + 10 }), "Carl Third", true, true, "Dora Fourth")
    local all = led:Derive()
    eq(all[20]["Alice Stone"].r, 1520)
    eq(all[60]["Alice Stone"].r, 1480)
    eq(all[60]["Bob Marsh"].r, 1520)
end)

test("test mode lifts level rules for the session only", function()
    ns.RULES.TEST = true
    local v = Ledger.Validate(raw({ la = 3, lb = 40 }))
    ns.RULES.TEST = nil
    ok(v, "accepted in test mode")
    ok(not Ledger.Validate(raw({ la = 3, lb = 40 })), "rejected again after")
end)
