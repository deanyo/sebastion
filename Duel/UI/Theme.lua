-- Theme.lua: shared look. Dark parchment panels, gold trim, Morpheus titles.
local _, ns = ...

local Theme = {}
ns.Theme = Theme

Theme.GOLD = { 0.90, 0.71, 0.13 }
Theme.GOLD_DIM = { 0.55, 0.43, 0.10 }
Theme.TEXT = { 0.93, 0.93, 0.95 }
Theme.MUTED = { 0.62, 0.62, 0.66 }
Theme.WIN = { 0.30, 0.90, 0.35 }
Theme.LOSS = { 0.95, 0.30, 0.28 }
Theme.TITLE_FONT = "Fonts\\MORPHEUS.TTF"

local BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
}
local THIN = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function Theme.Panel(frame, thin)
    frame:SetBackdrop(thin and THIN or BACKDROP)
    if thin then
        frame:SetBackdropColor(0.06, 0.06, 0.08, 0.85)
        frame:SetBackdropBorderColor(Theme.GOLD_DIM[1], Theme.GOLD_DIM[2], Theme.GOLD_DIM[3], 0.9)
    else
        frame:SetBackdropColor(1, 1, 1, 0.97)
    end
end

function Theme.Text(parent, size, color, font, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(font or STANDARD_TEXT_FONT, size or 12, flags or "")
    local c = color or Theme.TEXT
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetJustifyH("LEFT")
    return fs
end

function Theme.Title(parent, size)
    local fs = Theme.Text(parent, size or 20, Theme.GOLD, Theme.TITLE_FONT, "OUTLINE")
    fs:SetShadowOffset(1, -1)
    return fs
end

function Theme.Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 100, h or 22)
    b:SetText(text)
    return b
end

function Theme.ClassColor(class)
    local c = class and (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
    if c then return c.r, c.g, c.b end
    return Theme.TEXT[1], Theme.TEXT[2], Theme.TEXT[3]
end

function Theme.ClassHex(class)
    local r, g, b = Theme.ClassColor(class)
    return string.format("ff%02x%02x%02x", r * 255, g * 255, b * 255)
end

function Theme.ColorName(name, class)
    return "|c" .. Theme.ClassHex(class) .. name .. "|r"
end

local CLASS_TEX = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
function Theme.SetClassIcon(tex, class)
    local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        tex:SetTexture(CLASS_TEX)
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

function Theme.TierText(rating, games)
    local t = ns.Elo.Tier(rating, games)
    return string.format("|cff%02x%02x%02x%s|r", t.color[1] * 255, t.color[2] * 255, t.color[3] * 255, t.name), t
end

function Theme.Signed(n)
    n = n or 0
    if n > 0 then return "|cff4ce65a+" .. n .. "|r" end
    if n < 0 then return "|cfff24d47" .. n .. "|r" end
    return "|cff9e9ea8±0|r"
end

function Theme.Divider(parent, y, inset)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(Theme.GOLD_DIM[1], Theme.GOLD_DIM[2], Theme.GOLD_DIM[3], 0.6)
    t:SetHeight(1)
    t:SetPoint("TOPLEFT", inset or 12, y)
    t:SetPoint("TOPRIGHT", -(inset or 12), y)
    return t
end

-- Plain checkbox with a label; onChange(checked).
function Theme.Check(parent, label, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local fs = Theme.Text(parent, 12)
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return cb
end

return Theme
