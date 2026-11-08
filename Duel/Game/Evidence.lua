-- Evidence.lua: server-side duel statistics as independent evidence.
--
-- The modern client keeps "Duels won" / "Duels lost" statistics on the server.
-- While the opponent is nearby we can read *their* statistics through the
-- achievement comparison API; their client cannot fake those numbers. If the
-- opponent's server counter moved by exactly one, in the right column, the duel
-- really happened with that result. This is local evidence (shown in history);
-- it is not part of the shared record, and it only works if WoW Forever exposes
-- statistics at all - `/duel probe` reports what the client supports.
local _, ns = ...

local E = { STAT_WON = 319, STAT_LOST = 320 }
ns.Evidence = E

local pending       -- { unit, name, cb, timer }
local frame = CreateFrame("Frame")

local function num(v)
    if v == nil or not ns.Transport.Readable(v) then return nil end
    return tonumber((tostring(v):gsub("[^%d]", "")))
end

function E.Supported()
    return type(GetStatistic) == "function" and type(SetAchievementComparisonUnit) == "function"
        and type(GetComparisonStatistic) == "function" and num(GetStatistic(E.STAT_WON)) ~= nil
end

function E.Mine()
    if type(GetStatistic) ~= "function" then return nil end
    return num(GetStatistic(E.STAT_WON)), num(GetStatistic(E.STAT_LOST))
end

local function finish(won, lost)
    local p = pending
    pending = nil
    pcall(frame.UnregisterEvent, frame, "INSPECT_ACHIEVEMENT_READY")
    if p.timer then p.timer:Cancel() end
    if ClearAchievementComparisonUnit then pcall(ClearAchievementComparisonUnit) end
    p.cb(won, lost)
end

frame:SetScript("OnEvent", function()
    if not pending then return end
    local won = num(GetComparisonStatistic(E.STAT_WON))
    local lost = num(GetComparisonStatistic(E.STAT_LOST))
    finish(won, lost)
end)

-- Read the opponent's duel statistics. cb(won, lost) - nils when unavailable.
function E.Read(name, cb)
    if pending or not E.Supported() then return cb(nil, nil) end
    -- Never disturb the achievement window if the player has it open.
    local af = _G.AchievementFrame
    if af and af.IsShown and af:IsShown() then return cb(nil, nil) end
    local unit = ns.FindUnit(name)
    if not unit or not (CanInspect and CanInspect(unit)) then return cb(nil, nil) end
    pending = { name = name, cb = cb }
    if not pcall(frame.RegisterEvent, frame, "INSPECT_ACHIEVEMENT_READY") then return finish(nil, nil) end
    local ok = pcall(SetAchievementComparisonUnit, unit)
    if not ok then return finish(nil, nil) end
    pending.timer = C_Timer.NewTimer(5, function() if pending then finish(nil, nil) end end)
end

-- "server" when the opponent's counters moved consistently with our result.
function E.Judge(before, after, theyWon)
    if not before or not after or not before.won or not after.won or not before.lost or not after.lost then
        return nil
    end
    local dw, dl = after.won - before.won, after.lost - before.lost
    if theyWon and dw == 1 and dl == 0 then return "server" end
    if not theyWon and dw == 0 and dl == 1 then return "server" end
    return "mismatch"
end

-- Diagnostics for /duel probe.
function E.Probe()
    local lines = {}
    local function add(k, v) lines[#lines + 1] = k .. " = " .. tostring(v) end
    add("GetStatistic", type(GetStatistic))
    add("GetComparisonStatistic", type(GetComparisonStatistic))
    add("SetAchievementComparisonUnit", type(SetAchievementComparisonUnit))
    local w, l = E.Mine()
    add("my duels won/lost (319/320)", tostring(w) .. " / " .. tostring(l))
    add("statistics usable", E.Supported())
    return lines
end

return E
