-- Elo.lua: chess-style Elo with provisional K. Pure, deterministic.
--
-- Why Elo and not Glicko-2: ratings here are re-derived by every client from
-- the shared match ledger, in timestamp order. Elo is a single pass over that
-- list with integer deltas, so identical inputs give identical ratings on every
-- client and players can check the maths by hand. Glicko-2 needs rating periods
-- and per-period deviation updates, which are awkward to define when matches
-- trickle in late over a peer-to-peer network; its main benefit (uncertainty for
-- new players) is approximated by the provisional K below.
local _, ns = ...
local Util = ns.Util

local Elo = {}
ns.Elo = Elo

Elo.START = 1500
Elo.FLOOR = 100
Elo.PROVISIONAL_GAMES = 10   -- counted games before a rating is established

-- K-factor: FIDE-like. Fast movement while provisional, slower at the top.
function Elo.K(rating, games)
    if games < Elo.PROVISIONAL_GAMES then return 40 end
    if rating >= 2000 then return 16 end
    return 24
end

function Elo.Expected(ra, rb)
    return 1 / (1 + 10 ^ ((rb - ra) / 400))
end

-- Integer rating change for a player rated ra (games played) vs rb.
-- score: 1 win, 0 loss. weight: anti-farm multiplier in [0, 1].
function Elo.Delta(ra, games, rb, score, weight)
    weight = weight or 1
    if weight <= 0 then return 0 end
    local d = Util.Round(Elo.K(ra, games) * weight * (score - Elo.Expected(ra, rb)))
    if ra + d < Elo.FLOOR then d = Elo.FLOOR - ra end
    return d
end

-- Cosmetic tiers.
Elo.TIERS = {
    { min = 2000, name = "Grandmaster", color = { 1.00, 0.50, 0.00 } },
    { min = 1850, name = "Diamond",     color = { 0.73, 0.40, 1.00 } },
    { min = 1700, name = "Platinum",    color = { 0.30, 0.85, 0.85 } },
    { min = 1550, name = "Gold",        color = { 1.00, 0.82, 0.00 } },
    { min = 1400, name = "Silver",      color = { 0.78, 0.80, 0.85 } },
    { min = 0,    name = "Bronze",      color = { 0.80, 0.50, 0.25 } },
}
Elo.PROVISIONAL_TIER = { name = "Provisional", color = { 0.6, 0.6, 0.6 } }

function Elo.Tier(rating, games)
    if (games or 0) < Elo.PROVISIONAL_GAMES then return Elo.PROVISIONAL_TIER end
    for _, t in ipairs(Elo.TIERS) do
        if rating >= t.min then return t end
    end
    return Elo.TIERS[#Elo.TIERS]
end

return Elo
