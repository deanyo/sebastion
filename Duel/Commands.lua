-- Commands.lua: /ladder (and /duel <sub-command>) commands, debug and test tools.
--
-- /ladder is ours. /duel belongs to Blizzard; see Cmd.Intercept for how it reaches us.
local _, ns = ...
local Util, Ledger = ns.Util, ns.Ledger

local Cmd = {}
ns.Commands = Cmd

local HELP = {
    "|cffe6b422/ladder|r (or /duel with nothing targeted) - open the ladder window   |cffe6b422/duel lb|r - leaderboard   |cffe6b422/duel history|r",
    "|cffe6b422/duel profile Name Surname|r - a player's profile   |cffe6b422/duel settings|r",
    "|cffe6b422/duel challenge|r - challenge your target   |cffe6b422/duel Name Surname|r - challenge by name (Blizzard)",
    "|cffe6b422/duel status|r - network status   |cffe6b422/duel sync|r - announce and sync now",
    "|cffe6b422/duel probe|r - what this client supports   |cffe6b422/duel selftest|r - run the rating/protocol checks",
    "|cffe6b422/duel test win|lose|prompt|r - preview screens   |cffe6b422/duel pairs|r - most lopsided ranked pairs",
    "|cffe6b422/ladder testmode|r - this session only: ranked between any levels (results vanish on /reload)",
    "|cffe6b422/duel debug|r - toggle debug output   |cffe6b422/duel minimap|r - toggle the minimap button",
}

local function status()
    local v, p, d = 0, 0, 0
    for _, r in pairs(ns.ledger.store) do
        local st = Ledger.Status(r)
        if st == "verified" then v = v + 1 elseif st == "pending" then p = p + 1 else d = d + 1 end
    end
    local T = ns.Transport
    ns.Print("v%s proto %d · %d verified / %d pending / %d disputed · peers %d (30m) · directory %s (%d) · sent %d recv %d refused %d · queue %d",
        ns.VERSION, ns.PROTO, v, p, d, ns.Network.PeerCount(1800), ns.Directory.state or "?", #ns.Directory.names,
        T.stats.sent, T.stats.recv, T.stats.refused, T.QueueSize())
end

local function probe()
    local function t(x) return type(x) == "function" and "|cff4ce65ayes|r" or "|cfff24d47no|r" end
    ns.Print("Client: %s build %s, interface %s", tostring((GetBuildInfo())), tostring(select(2, GetBuildInfo())), tostring(select(4, GetBuildInfo())))
    ns.Print("Duel strings: KO=%q FLED=%q COUNTDOWN=%q", tostring(DUEL_WINNER_KNOCKOUT), tostring(DUEL_WINNER_RETREAT), tostring(DUEL_COUNTDOWN))
    ns.Print("StartDuel %s AcceptDuel %s GetServerTime %s issecretvalue %s", t(StartDuel), t(AcceptDuel), t(GetServerTime), t(issecretvalue))
    ns.Print("Channel roster %s · BNet game data %s · JoinTemporaryChannel %s",
        t(C_ChatInfo and C_ChatInfo.GetChannelRosterInfo), t(C_BattleNet and C_BattleNet.SendGameData), t(JoinTemporaryChannel))
    for _, line in ipairs(ns.Evidence.Probe()) do ns.Print("  " .. line) end
    local h = UnitHealth("player")
    ns.Print("UnitHealth readable: %s · my name: %q · level %s · class %s", tostring(ns.Transport.Readable(h)),
        tostring(ns.me.name), tostring(ns.me.level), tostring(ns.me.class))
    local unit = UnitExists("target") and "target"
    if unit then ns.Print("Target canonical name: %q", tostring(ns.UnitCanon(unit))) end
end

-- Pairs with the most one-sided ranked records (win-trading watch).
local function pairsReport()
    local pairs_ = {}
    for _, r in pairs(ns.ledger.store) do
        if Ledger.Status(r) == "verified" then
            local key = r.a .. " vs " .. r.b
            local e = pairs_[key] or { key = key, a = 0, b = 0 }
            pairs_[key] = e
            if r.w == "a" then e.a = e.a + 1 else e.b = e.b + 1 end
        end
    end
    local list = {}
    for _, e in pairs(pairs_) do
        e.n = e.a + e.b
        e.share = math.max(e.a, e.b) / e.n
        if e.n >= 3 then list[#list + 1] = e end
    end
    table.sort(list, function(x, y) if x.share ~= y.share then return x.share > y.share end return x.n > y.n end)
    if #list == 0 then return ns.Print("No pair has 3+ verified ranked games yet.") end
    for i = 1, math.min(10, #list) do
        local e = list[i]
        ns.Print("%s: %d-%d (%d%% one-sided)", e.key, e.a, e.b, math.floor(e.share * 100))
    end
end

-- Exercise the pure modules in memory (nothing touches the real ledger).
local function selftest()
    local okCount, fail = 0, {}
    local function check(name, cond) if cond then okCount = okCount + 1 else fail[#fail + 1] = name end end
    check("elo equal", ns.Elo.Delta(1500, 0, 1500, 1) == 20)
    check("elo upset", ns.Elo.Delta(1500, 20, 1700, 1) == 18)
    local queue, engines, t = {}, {}, 0
    local function mk(name)
        engines[name] = ns.Agreement.New({
            now = function() return t end, nonce = function() t = t + 1; return "x" .. t end,
            myName = function() return name end,
            me = function() return { level = 60, class = "MAGE", rating = 1500, games = 0 } end,
            pref = function() return "ranked" end, eligible = function() return true end,
            send = function(to, msg) queue[#queue + 1] = { name, to, msg } end,
        })
    end
    mk("Test Alpha"); mk("Test Beta")
    local function pump() while #queue > 0 do local m = table.remove(queue, 1); engines[m[2]]:OnMessage(m[1], m[3]) end end
    engines["Test Alpha"]:Begin("Test Beta", "C"); engines["Test Beta"]:Begin("Test Alpha", "D"); pump()
    check("lock ranked", engines["Test Beta"]:Lock() == "R"); pump()
    local ra, rb = engines["Test Alpha"]:Finish("Test Beta"), engines["Test Beta"]:Finish("Test Alpha")
    check("both ranked", ra.ranked and rb.ranked)
    check("same match id", ra.matchId == rb.matchId)
    local led = Ledger.New({})
    local rec = Ledger.Validate({ id = ra.matchId, ts = ns.ServerNow(), a = "Test Alpha", b = "Test Beta", w = "a",
        how = "K", la = 60, lb = 60, ca = "MAGE", cb = "MAGE" }, ns.ServerNow())
    check("record valid", rec ~= nil)
    if rec then
        rec.claim = { a = true, b = false }
        led:Ingest(rec, nil, "Test Alpha", ns.ServerNow())
        check("pending after one side", Ledger.Status(led:Get(rec.id)) == "pending")
        local copy = Ledger.Decode(Ledger.Encode(led:Get(rec.id)), ns.ServerNow())
        copy.claim = { a = true, b = true }
        led:Ingest(copy, "Test Beta", "Test Alpha", ns.ServerNow())
        check("verified after both", Ledger.Status(led:Get(rec.id)) == "verified")
        local players = led:Derive()
        check("winner +20", players[60] and players[60]["Test Alpha"] and players[60]["Test Alpha"].r == 1520)
    end
    if #fail == 0 then ns.Print("Self-test: |cff4ce65aall %d checks passed|r.", okCount)
    else ns.Print("Self-test: |cfff24d47%d failed|r: %s", #fail, table.concat(fail, ", ")) end
end

local function testPrompt()
    ns.Fire("SESSION", { opp = "Training Dummy", role = "D", peer = { class = "WARRIOR", level = 60 },
        eligible = true, myConsent = nil, theirConsent = true })
end

-- Run fn, collecting what it prints, and show it in the copyable report window.
local function report(title, fn)
    local lines, orig = {}, ns.Print
    ns.Print = function(fmt, ...)
        local ok, msg = pcall(string.format, fmt, ...)
        lines[#lines + 1] = select("#", ...) > 0 and (ok and msg or fmt) or fmt
        orig(fmt, ...)
    end
    local ok, err = pcall(fn)
    ns.Print = orig
    if not ok then lines[#lines + 1] = "ERROR: " .. tostring(err) end
    ns.Toast.Report(title, lines)
    return lines
end

local SUB = {
    [""] = function() ns.Main.Toggle() end,
    show = function() ns.Main.Toggle() end,
    lb = function() ns.Main.Show("board") end,
    leaderboard = function() ns.Main.Show("board") end,
    history = function() ns.Main.Show("history") end,
    settings = function() ns.Main.Show("settings") end,
    options = function() ns.Main.Show("settings") end,
    profile = function(rest)
        local name = Util.CanonName(rest)
        ns.Main.ShowProfile(name)
    end,
    challenge = function() if UnitExists("target") then StartDuel("target") end end,
    status = function() report("Duel Ladder - status", status) end,
    sync = function()
        ns.Network.Announce()
        ns.Toast.Show("Syncing", "Asked guild, group and known peers to compare ladders.", "info")
    end,
    probe = function() report("Duel Ladder - client probe", function() probe(); status() end) end,
    selftest = function()
        local lines = report("Duel Ladder - self-test", selftest)
        local passed = lines[#lines] and lines[#lines]:find("all %d+ checks passed")
        ns.Toast.Show(passed and "Self-test passed" or "Self-test FAILED", lines[#lines], passed and "success" or "error")
    end,
    pairs = function() report("Duel Ladder - most one-sided pairs", pairsReport) end,
    help = function() ns.Toast.Report("Duel Ladder - commands", HELP) end,
    debug = function()
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Toast.Show("Debug " .. (ns.db.settings.debug and "on" or "off"), "Network messages will " ..
            (ns.db.settings.debug and "" or "not ") .. "be printed in chat.", "info")
    end,
    minimap = function()
        ns.db.settings.minimap = not ns.db.settings.minimap
        ns.Minimap.Update()
    end,
    testmode = function()
        -- Session-only: lift the level rule so two low-level characters can test ranked.
        -- Matches recorded now break the real rules, so DB.Load drops them at the next
        -- login/reload, and every other client rejects them: the real ladder never sees them.
        local R = ns.RULES
        if not R.TEST then
            R.TEST = true
            ns.Toast.Show("TEST MODE ON", "Any two levels can duel ranked. Test results vanish at your next /reload. Both players need test mode.", "warn")
        else
            R.TEST = nil
            ns.Toast.Show("Test mode off", "Normal bracket rules again.", "info")
        end
    end,
    test = function(rest)
        if rest == "lose" then ns.Result.Demo(false)
        elseif rest == "prompt" then testPrompt()
        else ns.Result.Demo(true) end
    end,
}

function Cmd.Run(msg)
    msg = Util.Trim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    local fn = SUB[(cmd or ""):lower()]
    if not ns.ledger then return ns.Print("Still loading.") end
    if fn then fn(rest) return true end
    return false
end

-- Our own alias, never ambiguous.
SLASH_DUELLADDER1 = "/ladder"
SLASH_DUELLADDER2 = "/duelladder"
SlashCmdList.DUELLADDER = function(msg)
    if not Cmd.Run(msg) then for _, l in ipairs(HELP) do ns.Print(l) end end
end

-- /duel is a secure Blizzard command (it calls StartDuel(msg)) that addons cannot
-- replace. We only see it through our StartDuel hook (Controller.lua): a bare
-- "/duel" with no player targeted, or "/duel <one of our sub-commands>", runs ours.
function Cmd.Intercept(arg)
    if type(arg) ~= "string" or not ns.Transport.Readable(arg) then return false end
    local msg = Util.Trim(arg)
    if msg == "" then
        if UnitExists("target") and UnitIsPlayer("target") then return false end
        ns.Main.Toggle()
        return true
    end
    local cmd = msg:match("^(%S+)")
    if cmd and SUB[cmd:lower()] then
        Cmd.Run(msg)
        return true
    end
    return false
end

return Cmd
