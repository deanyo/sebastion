-- DuelTracker.lua: one duel's lifecycle from game signals. Pure logic.
--
--   idle -> requested (we challenged / were challenged)
--        -> countdown ("Duel starting: 3")
--        -> active   (countdown elapsed)
--        -> result   (winner system message naming us)   | cancelled
--
-- Signals and their WoW sources (wired in Game/Controller.lua):
--   RequestOut(opp)   StartDuel hook (menu, /duel)
--   RequestIn(opp)    DUEL_REQUESTED
--   Countdown(n)      CHAT_MSG_SYSTEM matching DUEL_COUNTDOWN
--   Winner(kind, w, l) CHAT_MSG_SYSTEM matching DUEL_WINNER_KNOCKOUT / _RETREAT
--   Finished()        DUEL_FINISHED (fires for results, declines and cancels)
-- The winner line and DUEL_FINISHED may come in either order: after DUEL_FINISHED
-- we wait FINISH_GRACE seconds for the line before calling the duel cancelled.
local _, ns = ...

local Tracker = {}
Tracker.__index = Tracker
ns.DuelTracker = Tracker

Tracker.FINISH_GRACE = 4
Tracker.REQUEST_TIMEOUT = 120   -- a request nobody answers
Tracker.MAX_DURATION = 1800

-- deps: now(), after(sec, fn), myName(), and callbacks
--   onRequest(opp, role), onCountdown(opp, role), onResult(res), onCancel(opp, reason, state)
function Tracker.New(deps)
    return setmetatable({ deps = deps, state = "idle", gen = 0 }, Tracker)
end

function Tracker:_reset()
    self.state, self.opp, self.role = "idle", nil, nil
    self.startAt, self.requestAt, self.finishedAt = nil, nil, nil
    self.gen = self.gen + 1
end

function Tracker:_request(opp, role)
    if not opp then return end
    if self.state ~= "idle" and self.opp == opp and self.state ~= "requested" then return end
    if self.state ~= "idle" and self.opp ~= opp then
        local prev = self.opp
        local st = self.state
        self:_reset()
        self.deps.onCancel(prev, "replaced", st)
    end
    self:_reset()
    self.state, self.opp, self.role, self.requestAt = "requested", opp, role, self.deps.now()
    local gen = self.gen
    self.deps.after(Tracker.REQUEST_TIMEOUT, function()
        if self.gen == gen and self.state == "requested" then
            local o = self.opp
            self:_reset()
            self.deps.onCancel(o, "timeout", "requested")
        end
    end)
    self.deps.onRequest(opp, role)
end

function Tracker:RequestOut(opp) self:_request(opp, "C") end
function Tracker:RequestIn(opp) self:_request(opp, "D") end

function Tracker:Countdown(seconds)
    if self.state ~= "requested" then return end
    self.state = "countdown"
    self.startAt = self.deps.now() + (tonumber(seconds) or 3)
    self.deps.onCountdown(self.opp, self.role)
end

-- kind: "K" knockout or "F" fled. Names already canonical.
function Tracker:Winner(kind, winner, loser)
    local me = self.deps.myName()
    if winner ~= me and loser ~= me then return false end
    local opp = winner == me and loser or winner
    local res = {
        opp = opp, won = winner == me, how = kind, winner = winner, loser = loser,
        role = (self.opp == opp) and self.role or nil,
        tracked = self.opp == opp and self.state ~= "idle",
        duration = self.startAt and math.max(0, self.deps.now() - self.startAt) or nil,
    }
    self:_reset()
    self.deps.onResult(res)
    return true
end

function Tracker:Finished()
    if self.state == "idle" then return end
    if self.state == "requested" then
        -- Declined or cancelled before the countdown.
        local o, st = self.opp, self.state
        self:_reset()
        self.deps.onCancel(o, "declined", st)
        return
    end
    self.finishedAt = self.deps.now()
    local gen = self.gen
    self.deps.after(Tracker.FINISH_GRACE, function()
        if self.gen == gen and self.state ~= "idle" then
            local o, st = self.opp, self.state
            self:_reset()
            -- No winner line: cancelled, out of range, or a disconnect.
            self.deps.onCancel(o, "unresolved", st)
        end
    end)
end

function Tracker:Reset() self:_reset() end

return Tracker
