local ns = load_ns()
local Tracker = ns.DuelTracker

local function make()
    local clock = new_clock()
    local log = {}
    local t = Tracker.New({
        now = clock.now, after = clock.after,
        myName = function() return "Alice Stone" end,
        onRequest = function(opp, role) log[#log + 1] = "req:" .. opp .. ":" .. role end,
        onCountdown = function(opp) log[#log + 1] = "count:" .. opp end,
        onResult = function(r) log[#log + 1] = "res:" .. r.opp .. ":" .. (r.won and "W" or "L") .. ":" .. r.how end,
        onCancel = function(opp, reason) log[#log + 1] = "cancel:" .. tostring(opp) .. ":" .. reason end,
    })
    return t, log, clock
end

test("full duel, winner line before DUEL_FINISHED", function()
    local t, log, clock = make()
    t:RequestOut("Bob Marsh"); t:Countdown(3); clock.advance(20)
    t:Winner("K", "Alice Stone", "Bob Marsh"); t:Finished(); clock.advance(10)
    eq(log, { "req:Bob Marsh:C", "count:Bob Marsh", "res:Bob Marsh:W:K" })
    eq(t.state, "idle")
end)

test("winner line after DUEL_FINISHED within grace", function()
    local t, log, clock = make()
    t:RequestIn("Bob Marsh"); t:Countdown(3)
    t:Finished(); clock.advance(1)
    t:Winner("F", "Bob Marsh", "Alice Stone"); clock.advance(10)
    eq(log, { "req:Bob Marsh:D", "count:Bob Marsh", "res:Bob Marsh:L:F" })
end)

test("DUEL_FINISHED without a winner -> unresolved", function()
    local t, log, clock = make()
    t:RequestIn("Bob Marsh"); t:Countdown(3); t:Finished(); clock.advance(10)
    eq(log[3], "cancel:Bob Marsh:unresolved")
end)

test("declined before countdown", function()
    local t, log = make()
    t:RequestOut("Bob Marsh"); t:Finished()
    eq(log[2], "cancel:Bob Marsh:declined")
end)

test("request timeout", function()
    local t, log, clock = make()
    t:RequestOut("Bob Marsh"); clock.advance(Tracker.REQUEST_TIMEOUT + 1)
    eq(log[2], "cancel:Bob Marsh:timeout")
end)

test("other players' duels are ignored", function()
    local t, log = make()
    ok(not t:Winner("K", "Carl Third", "Dora Fourth"))
    eq(#log, 0)
end)

test("result for an untracked duel (after /reload) still reports", function()
    local t, log = make()
    t:Winner("K", "Bob Marsh", "Alice Stone")
    eq(log, { "res:Bob Marsh:L:K" })
end)

test("a new request replaces an old one", function()
    local t, log = make()
    t:RequestOut("Bob Marsh"); t:RequestIn("Carl Third")
    eq(log, { "req:Bob Marsh:C", "cancel:Bob Marsh:replaced", "req:Carl Third:D" })
end)
