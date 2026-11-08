local ns = load_ns()
local Agreement = ns.Agreement

-- Two engines wired together; messages are delivered when pump() is called.
local function pair(opts)
    opts = opts or {}
    local clock = new_clock()
    local queue = {}
    local engines = {}
    local nonceN = 0
    local function make(name, prefKey, level)
        local deps = {
            now = clock.now,
            nonce = function() nonceN = nonceN + 1; return "n" .. nonceN end,
            myName = function() return name end,
            me = function() return { level = level or 60, class = "MAGE", rating = 1500, games = 0 } end,
            pref = function() return opts[prefKey] or "ask" end,
            eligible = function(opp, peer)
                if math.abs((peer.level or 0) - (level or 60)) > 3 then return false, "level" end
                return true
            end,
            send = function(target, msg) queue[#queue + 1] = { from = name, to = target, msg = msg } end,
        }
        engines[name] = Agreement.New(deps)
        return engines[name]
    end
    local A = make("Alice Stone", "prefA", opts.levelA)
    local B = make("Bob Marsh", "prefB", opts.levelB)
    local function pump(drop)
        while #queue > 0 do
            local m = table.remove(queue, 1)
            if not (drop and drop(m)) then engines[m.to]:OnMessage(m.from, m.msg) end
        end
    end
    return A, B, pump, clock
end

test("both consent -> ranked on both sides with the same match id", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    A:Consent(true); B:Consent(true); pump()
    eq(B:Lock(), "R"); pump()
    local ra, rb = A:Finish("Bob Marsh"), B:Finish("Alice Stone")
    ok(ra.ranked and rb.ranked)
    eq(ra.matchId, rb.matchId)
    ok(ra.matchId and #ra.matchId == 12)
end)

test("one side says casual -> casual", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    A:Consent(true); B:Consent(false); pump()
    eq(B:Lock(), "C"); pump()
    ok(not A:Finish("Bob Marsh").ranked)
end)

test("no answer before lock -> casual", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    B:Consent(true); pump()
    eq(B:Lock(), "C")
end)

test("challenger never receives LOCK -> casual for the challenger", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    A:Consent(true); B:Consent(true); pump()
    B:Lock(); pump(function(m) return m.msg:sub(1, 2) == "L~" end)
    ok(not A:Finish("Bob Marsh").ranked)
    ok(B:Finish("Alice Stone").ranked)  -- B attests ranked; A never does, so it never verifies
end)

test("hello arriving before our own duel event is kept", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C"); pump()     -- B has no session yet: stashed
    B:Begin("Alice Stone", "D"); pump()
    ok(B:Session().peer, "B knows A")
    ok(A:Session().peer, "A knows B")
end)

test("auto preferences", function()
    local A, B, pump = pair({ prefA = "ranked", prefB = "ranked" })
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    eq(B:Lock(), "R")
end)

test("ineligible levels force casual even if both click ranked", function()
    local A, B, pump = pair({ levelA = 60, levelB = 40 })
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    A:Consent(true); B:Consent(true); pump()
    eq(B:Session().eligible, false)
    eq(B:Lock(), "C")
end)

test("consent cannot change after lock; stale replies are ignored", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C"); B:Begin("Alice Stone", "D"); pump()
    B:Consent(false); B:Lock(); pump()
    ok(not B:Consent(true))
    B:OnMessage("Alice Stone", "R~wrongnonce~1~")
    eq(B:Session().theirConsent, nil)
end)

test("sessions expire", function()
    local A, B, pump, clock = pair()
    A:Begin("Bob Marsh", "C")
    clock.advance(Agreement.STALE + 1)
    eq(A:Session(), nil)
end)

test("other protocol versions are casual", function()
    local A, B, pump = pair()
    A:Begin("Bob Marsh", "C")
    A:OnMessage("Bob Marsh", "H~99~9.0.0~zz~D~60~MAGE~1500~0")
    eq(A:Session().eligible, false); eq(A:Session().reason, "they_newer")
end)
