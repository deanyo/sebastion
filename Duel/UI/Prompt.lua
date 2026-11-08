-- Prompt.lua: compact Ranked / Casual choice shown next to the duel request.
local _, ns = ...
local Theme, Elo = ns.Theme, ns.Elo

local P = {}
ns.Prompt = P

local f

local function build()
    f = CreateFrame("Frame", "DuelLadderPrompt", UIParent, "BackdropTemplate")
    f:SetSize(330, 118)
    f:SetPoint("TOP", UIParent, "TOP", 0, -260)
    f:SetFrameStrata("DIALOG")
    Theme.Panel(f)
    f:Hide()

    f.title = Theme.Title(f, 17)
    f.title:SetPoint("TOP", 0, -14)
    f.title:SetJustifyH("CENTER")
    f.vs = Theme.Text(f, 12)
    f.vs:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
    f.vs:SetJustifyH("CENTER")
    f.note = Theme.Text(f, 11, Theme.MUTED)
    f.note:SetPoint("TOP", f.vs, "BOTTOM", 0, -3)
    f.note:SetWidth(300)
    f.note:SetJustifyH("CENTER")

    f.ranked = Theme.Button(f, "Ranked", 120, 24)
    f.ranked:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 14)
    f.ranked:SetScript("OnClick", function() ns.agreement:Consent(true) end)
    f.casual = Theme.Button(f, "Casual", 120, 24)
    f.casual:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 14)
    f.casual:SetScript("OnClick", function() ns.agreement:Consent(false) end)
end

local function choiceText(v)
    if v == true then return "|cff4ce65aRanked|r" end
    if v == false then return "|cff9e9ea8Casual|r" end
    return "|cffffd100deciding...|r"
end

local hideTimer
local function update(s)
    if not s then
        if f and f:IsShown() and not hideTimer then
            hideTimer = C_Timer.NewTimer(1.5, function() hideTimer = nil; if not ns.agreement:Session() then f:Hide() end end)
        end
        return
    end
    -- Opponent without the addon: nothing to show.
    if not s.peer then return end
    if not f then build() end
    if hideTimer then hideTimer:Cancel(); hideTimer = nil end
    local peer = s.peer
    local p = ns.players[s.opp]
    local rating = p and p.r or Elo.START
    local tier = Theme.TierText(rating, p and p.counted or 0)
    f.vs:SetText(string.format("vs %s  ·  %d  %s", Theme.ColorName(s.opp, peer.class), rating, tier))

    if s.locked then
        f.title:SetText(s.locked == "R" and "Ranked duel" or "Casual duel")
        f.title:SetTextColor(s.locked == "R" and 1 or 0.8, s.locked == "R" and 0.82 or 0.8, s.locked == "R" and 0 or 0.8)
        local why = {
            you = "You chose casual.", you_slow = "You didn't pick Ranked before the duel started.",
            they = s.opp .. " chose casual.", they_slow = s.opp .. " didn't pick Ranked before the duel started.",
            ineligible = "Not eligible: " .. tostring(ns.Controller.REASONS[s.reason] or s.reason),
            no_addon = s.opp .. " doesn't have Duel Ladder.",
        }
        if s.locked == "R" then
            f.note:SetText("Locked. The result will count for both of you.")
        else
            local reason = why[s.lockReason] or "This duel will not affect ratings."
            f.note:SetText("Not ranked: " .. reason)
            if not s.toldWhy then
                s.toldWhy = true
                ns.Toast.Show("Casual duel", reason .. " Both pick Ranked before accepting next time.", "warn")
            end
        end
        f.ranked:Hide(); f.casual:Hide()
        f:SetHeight(84)
        C_Timer.After(4, function() if f:IsShown() and ns.agreement:Session() == s then f:Hide() end end)
    elseif s.eligible == false then
        f.title:SetText("Casual duel")
        f.title:SetTextColor(0.8, 0.8, 0.8)
        f.note:SetText("Not eligible for ranked: " .. (ns.Controller.REASONS[s.reason] or tostring(s.reason)))
        f.ranked:Hide(); f.casual:Hide()
        f:SetHeight(84)
    else
        f.title:SetText("Ranked or casual?")
        f.title:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
        local weight = ns.PairWeightNow(s.opp)
        local extra = ""
        if weight == 0 then extra = "  |cffff9933Repeat opponent: will not count today.|r"
        elseif weight < 1 then extra = string.format("  |cffff9933Repeat opponent: counts %d%%.|r", weight * 100) end
        f.note:SetText(string.format("You: %s   ·   Them: %s%s", choiceText(s.myConsent), choiceText(s.theirConsent), extra)
            .. (s.role == "D" and "\n|cff9e9ea8Wait for both to pick before accepting the duel.|r" or ""))
        f.ranked:SetShown(true); f.casual:SetShown(true)
        f.ranked:SetEnabled(s.myConsent ~= true)
        f.casual:SetEnabled(s.myConsent ~= false)
        f:SetHeight(s.role == "D" and 132 or 118)
    end
    f:Show()
end

ns.Listen(function(event, session)
    if event == "SESSION" then update(session) end
    if event == "RESULT" or event == "CANCELLED" then if f then f:Hide() end end
end)

return P
