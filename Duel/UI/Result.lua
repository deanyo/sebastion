-- Result.lua: the victory / defeat banner with the rating change.
local _, ns = ...
local Theme, Elo = ns.Theme, ns.Elo

local R = {}
ns.Result = R

local f, shownMatch

local function build()
    f = CreateFrame("Button", "DuelLadderResult", UIParent, "BackdropTemplate")
    f:SetSize(380, 168)
    f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    f:SetFrameStrata("DIALOG")
    Theme.Panel(f)
    f:Hide()
    f:SetScript("OnClick", function(self) self:Hide() end)

    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.glow:SetPoint("TOPLEFT", 8, -8)
    f.glow:SetPoint("BOTTOMRIGHT", -8, 8)
    f.glow:SetTexture("Interface\\Buttons\\WHITE8X8")

    f.banner = Theme.Text(f, 40, Theme.GOLD, Theme.TITLE_FONT, "THICKOUTLINE")
    f.banner:SetPoint("TOP", 0, -16)
    f.banner:SetJustifyH("CENTER")
    f.vs = Theme.Text(f, 13)
    f.vs:SetPoint("TOP", f.banner, "BOTTOM", 0, -2)
    f.vs:SetJustifyH("CENTER")

    f.rating = Theme.Text(f, 26, Theme.TEXT, Theme.TITLE_FONT, "OUTLINE")
    f.rating:SetPoint("TOP", f.vs, "BOTTOM", 0, -10)
    f.rating:SetJustifyH("CENTER")
    f.tier = Theme.Text(f, 12)
    f.tier:SetPoint("TOP", f.rating, "BOTTOM", 0, -3)
    f.tier:SetJustifyH("CENTER")
    f.status = Theme.Text(f, 11, Theme.MUTED)
    f.status:SetPoint("BOTTOM", 0, 14)
    f.status:SetJustifyH("CENTER")
end

local STATUS = {
    pending = "|cffffd100Awaiting opponent's confirmation...|r",
    verified = "|cff4ce65aVerified by both players|r",
    disputed = "|cfff24d47Disputed - this result does not count|r",
}

local function glow(tex, r, g, b)
    local ok = CreateColor and pcall(tex.SetGradient, tex, "VERTICAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 0.45))
    if not ok then tex:SetColorTexture(r, g, b, 0.25) end
end

local hideTimer
local function show(entry, proj, status)
    if not ns.db.settings.resultScreen then return end
    if not f then build() end
    local won = entry.result == "W"
    f.banner:SetText(won and "VICTORY" or "DEFEAT")
    if won then
        f.banner:SetTextColor(1, 0.82, 0.1)
        glow(f.glow, 0.35, 0.25, 0.02)
    else
        f.banner:SetTextColor(0.85, 0.18, 0.15)
        glow(f.glow, 0.35, 0.03, 0.03)
    end
    local how = entry.how == "F" and (won and " (they fled)" or " (you fled)") or ""
    f.vs:SetText("vs " .. Theme.ColorName(entry.opp, entry.class) .. how)
    shownMatch = entry.match
    if entry.mode == "R" and proj then
        local after = proj.before + proj.delta
        f.rating:SetText(string.format("%d  >  %d   %s", proj.before, after, Theme.Signed(proj.delta)))
        local me = ns.Me()
        local tierText = Theme.TierText(after, (me.counted or 0) + ((proj.weight or 0) > 0 and 1 or 0))
        local note = ""
        if proj.weight == 0 then note = "  |cffff9933(repeat opponent - no rating change)|r"
        elseif proj.weight and proj.weight < 1 then note = string.format("  |cffff9933(counted %d%%)|r", proj.weight * 100) end
        f.tier:SetText(tierText .. note)
        f.status:SetText(STATUS[status] or STATUS.pending)
        f.rating:Show(); f.tier:Show()
        f:SetHeight(168)
    else
        f.rating:SetText("")
        f.tier:SetText(entry.mode == "R" and "Ranked result could not be recorded" or "Casual duel - rating unchanged")
        f.status:SetText("")
        f:SetHeight(130)
    end
    f:SetAlpha(0)
    f:Show()
    UIFrameFadeIn(f, 0.3, 0, 1)
    if ns.db.settings.sound then
        pcall(PlaySound, won and (SOUNDKIT and SOUNDKIT.LEVEL_UP or 888) or (SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED or 847))
    end
    if hideTimer then hideTimer:Cancel() end
    hideTimer = C_Timer.NewTimer(12, function()
        hideTimer = nil
        if f:IsShown() then UIFrameFadeOut(f, 0.6, 1, 0); C_Timer.After(0.65, function() f:Hide() end) end
    end)
end

ns.Listen(function(event, a, b, c)
    if event == "RESULT" then
        show(a, b, c)
    elseif event == "STATUS" and f and f:IsShown() and a == shownMatch then
        f.status:SetText(STATUS[b] or "")
        if b == "verified" then
            -- Confirmed numbers from the full replay.
            local d, r = ns.deltas[a], ns.ledger:Get(a)
            if d and r then
                local side = ns.Ledger.SideOf(r, ns.me.name)
                local before = side == "a" and d.ra or d.rb
                local delta = side == "a" and d.da or d.db
                f.rating:SetText(string.format("%d  >  %d   %s", before, before + delta, Theme.Signed(delta)))
            end
        end
    end
end)

-- Preview for /duel test result
function R.Demo(won)
    show({ result = won and "W" or "L", opp = "Training Dummy", mode = "R", match = nil, class = "WARRIOR" },
        { before = 1512, delta = won and 18 or -17, weight = 1 }, "pending")
end

return R
