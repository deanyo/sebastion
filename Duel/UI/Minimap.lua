-- Minimap.lua: draggable minimap button (no library needed).
local _, ns = ...
local Theme = ns.Theme

local M = {}
ns.Minimap = M

local b

local function place()
    local angle = math.rad(ns.db.settings.minimapAngle or 215)
    local radius = (Minimap:GetWidth() / 2) + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function build()
    b = CreateFrame("Button", "DuelLadderMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture("Interface\\Icons\\Ability_DualWield")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ns.Main.Toggle("board") else ns.Main.Toggle() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            ns.db.settings.minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
            place()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Duel Ladder", Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
        local me = ns.Me()
        GameTooltip:AddDoubleLine("Rating", me.r .. "  " .. (Theme.TierText(me.r, me.counted)), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Ranked W-L", me.w .. " - " .. me.l, 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddLine("Left-click: profile   Right-click: leaderboard", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    place()
end

function M.Update()
    if ns.db.settings.minimap then
        if not b then build() end
        place()
        b:Show()
    elseif b then
        b:Hide()
    end
end

ns.Listen(function(event) if event == "READY" then M.Update() end end)

return M
