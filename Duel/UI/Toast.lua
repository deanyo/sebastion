-- Toast.lua: on-screen notifications (so nothing important is chat-only),
-- plus a copyable diagnostics window for selftest / probe / status output.
local _, ns = ...
local Theme = ns.Theme

local Toast = {}
ns.Toast = Toast

local KINDS = {
    info    = { color = { 0.90, 0.71, 0.13 }, icon = "Interface\\Icons\\Ability_DualWield" },
    success = { color = { 0.30, 0.90, 0.35 }, icon = "Interface\\RaidFrame\\ReadyCheck-Ready" },
    warn    = { color = { 1.00, 0.60, 0.20 }, icon = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew" },
    error   = { color = { 0.95, 0.30, 0.28 }, icon = "Interface\\RaidFrame\\ReadyCheck-NotReady" },
}
local MAX, LIFE = 4, 7
local pool, active = {}, {}
local anchor

local function layout()
    for i, t in ipairs(active) do
        t:ClearAllPoints()
        t:SetPoint("TOP", anchor, "TOP", 0, -(i - 1) * 58)
    end
end

local function release(t)
    for i, x in ipairs(active) do
        if x == t then table.remove(active, i); break end
    end
    t:Hide()
    pool[#pool + 1] = t
    layout()
end

local function make()
    local t = CreateFrame("Button", nil, anchor, "BackdropTemplate")
    t:SetSize(340, 52)
    t:SetFrameStrata("DIALOG")
    Theme.Panel(t, true)
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(30, 30)
    t.icon:SetPoint("LEFT", 12, 0)
    t.title = Theme.Text(t, 13, nil, nil, "OUTLINE")
    t.title:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 10, 2)
    t.title:SetPoint("RIGHT", -10, 0)
    t.text = Theme.Text(t, 11, Theme.TEXT)
    t.text:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -3)
    t.text:SetPoint("RIGHT", -10, 0)
    t.text:SetMaxLines(2)
    t:SetScript("OnClick", function(self) release(self) end)
    return t
end

-- kind: info | success | warn | error
function Toast.Show(title, text, kind)
    if not anchor then
        anchor = CreateFrame("Frame", "DuelLadderToasts", UIParent)
        anchor:SetSize(340, 1)
        anchor:SetPoint("TOP", UIParent, "TOP", 0, -90)
    end
    local k = KINDS[kind or "info"] or KINDS.info
    if #active >= MAX then release(active[#active]) end
    local t = table.remove(pool) or make()
    t.icon:SetTexture(k.icon)
    t.title:SetText(title or "")
    t.title:SetTextColor(k.color[1], k.color[2], k.color[3])
    t.text:SetText(text or "")
    t:SetBackdropBorderColor(k.color[1], k.color[2], k.color[3], 0.9)
    table.insert(active, 1, t)
    layout()
    t:SetAlpha(1)
    t:Show()
    local token = {}
    t.token = token
    C_Timer.After(LIFE, function()
        if t.token == token and t:IsShown() then
            UIFrameFadeOut(t, 0.5, 1, 0)
            C_Timer.After(0.55, function() if t.token == token then release(t) end end)
        end
    end)
    return t
end

---------------------------------------------------------------------------
-- Diagnostics window: copyable text.
---------------------------------------------------------------------------
local diag
function Toast.Report(title, lines)
    if not diag then
        diag = CreateFrame("Frame", "DuelLadderReport", UIParent, "BackdropTemplate")
        diag:SetSize(560, 340)
        diag:SetPoint("CENTER", 0, 60)
        diag:SetFrameStrata("DIALOG")
        diag:SetMovable(true)
        diag:EnableMouse(true)
        diag:RegisterForDrag("LeftButton")
        diag:SetScript("OnDragStart", diag.StartMoving)
        diag:SetScript("OnDragStop", diag.StopMovingOrSizing)
        Theme.Panel(diag)
        tinsert(UISpecialFrames, "DuelLadderReport")
        diag.title = Theme.Title(diag, 18)
        diag.title:SetPoint("TOPLEFT", 18, -16)
        local hint = Theme.Text(diag, 10, Theme.MUTED)
        hint:SetPoint("TOPRIGHT", -40, -20)
        hint:SetText("Ctrl+A, Ctrl+C to copy")
        local close = CreateFrame("Button", nil, diag, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -6, -6)
        local scroll = CreateFrame("ScrollFrame", nil, diag, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 18, -44)
        scroll:SetPoint("BOTTOMRIGHT", -36, 18)
        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject(ChatFontNormal)
        box:SetWidth(500)
        box:SetScript("OnEscapePressed", function() diag:Hide() end)
        scroll:SetScrollChild(box)
        diag.box = box
    end
    diag.title:SetText(title)
    -- Plain text (no colour codes) so it copies cleanly.
    local plain = {}
    for i, l in ipairs(lines) do plain[i] = (tostring(l):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    diag.box:SetText(table.concat(plain, "\n"))
    diag:Show()
    diag.box:SetFocus()
    diag.box:HighlightText()
end

return Toast
