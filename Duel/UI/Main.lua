-- Main.lua: the /duel window - Profile, Leaderboard, History, Settings.
local _, ns = ...
local Theme, Elo, Ledger = ns.Theme, ns.Elo, ns.Ledger

local Main = {}
ns.Main = Main

local W, H = 720, 490
local f, pages, tabs = nil, {}, {}
local activeTab = "profile"
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function classDisplay(class)
    return class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class or "?"
end

local function winRate(p)
    local n = (p.w or 0) + (p.l or 0)
    if n == 0 then return "-" end
    return string.format("%d%%", math.floor(100 * p.w / n + 0.5))
end

---------------------------------------------------------------------------
-- Generic scrolling list (pooled rows, mouse wheel + thumb)
---------------------------------------------------------------------------
local function makeList(parent, rowCount, rowHeight, build, fill)
    local list = CreateFrame("Frame", nil, parent)
    list.offset, list.items, list.rows = 0, {}, {}
    for i = 1, rowCount do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", -14, -(i - 1) * rowHeight)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)
        row.bg = bg
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.12)
        build(row)
        list.rows[i] = row
    end
    local bar = CreateFrame("Slider", nil, list)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar:SetWidth(10)
    bar:SetOrientation("VERTICAL")
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(0, 0, 0, 0.4)
    bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    bar:GetThumbTexture():SetSize(14, 22)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    list.bar = bar

    function list:Refresh()
        local maxOffset = math.max(0, #self.items - rowCount)
        if self.offset > maxOffset then self.offset = maxOffset end
        bar:SetMinMaxValues(0, maxOffset)
        bar:SetValue(self.offset)
        if maxOffset == 0 then bar:Hide() else bar:Show() end
        for i, row in ipairs(self.rows) do
            local item = self.items[i + self.offset]
            if item then
                row.item = item
                fill(row, item, i + self.offset)
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
    end
    function list:SetItems(items)
        self.items = items or {}
        self:Refresh()
    end
    bar:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v + 0.5)
        if v ~= list.offset then list.offset = v; list:Refresh() end
    end)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta * 3)
        self:Refresh()
    end)
    return list
end

---------------------------------------------------------------------------
-- Profile
---------------------------------------------------------------------------
local profile = {}

local function drawGraph(g, hist)
    for _, l in ipairs(g.lines) do l:Hide() end
    for _, t in ipairs(g.labels) do t:Hide() end
    local pts = { Elo.START }
    local first = math.max(1, #hist - 59)  -- last 60 games
    if first > 1 then pts[1] = hist[first - 1][2] end
    for i = first, #hist do pts[#pts + 1] = hist[i][2] end
    if #pts < 2 then
        g.empty:Show()
        return
    end
    g.empty:Hide()
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(pts) do lo, hi = math.min(lo, v), math.max(hi, v) end
    lo, hi = lo - 15, hi + 15
    local gw, gh = g:GetWidth() - 40, g:GetHeight() - 16
    local function xy(i, v) return 36 + (i - 1) / (#pts - 1) * gw, 8 + (v - lo) / (hi - lo) * gh end
    local n = 0
    local function line(x1, y1, x2, y2, r, gg, b, a, thick)
        n = n + 1
        local l = g.lines[n]
        if not l then l = g:CreateLine(nil, "ARTWORK"); g.lines[n] = l end
        l:SetThickness(thick or 2)
        l:SetColorTexture(r, gg, b, a or 1)
        l:SetStartPoint("BOTTOMLEFT", g, x1, y1)
        l:SetEndPoint("BOTTOMLEFT", g, x2, y2)
        l:Show()
    end
    -- Gridlines with labels.
    for k = 0, 2 do
        local v = math.floor(lo + (hi - lo) * k / 2 + 0.5)
        local _, y = xy(1, v)
        line(36, y, 36 + gw, y, 1, 1, 1, 0.08, 1)
        local t = g.labels[k + 1]
        t:SetText(v)
        t:ClearAllPoints()
        t:SetPoint("RIGHT", g, "BOTTOMLEFT", 32, y)
        t:Show()
    end
    for i = 2, #pts do
        local x1, y1 = xy(i - 1, pts[i - 1])
        local x2, y2 = xy(i, pts[i])
        local up = pts[i] >= pts[i - 1]
        local c = up and Theme.GOLD or { 0.8, 0.35, 0.3 }
        line(x1, y1, x2, y2, c[1], c[2], c[3], 1, 2)
    end
end

local function buildProfile(page)
    local card = CreateFrame("Frame", nil, page, "BackdropTemplate")
    Theme.Panel(card, true)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", 0, 0)
    card:SetHeight(108)

    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(64, 64)
    icon:SetPoint("TOPLEFT", 14, -14)
    profile.icon = icon

    profile.name = Theme.Title(card, 22)
    profile.name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
    profile.sub = Theme.Text(card, 12, Theme.MUTED)
    profile.sub:SetPoint("TOPLEFT", profile.name, "BOTTOMLEFT", 0, -4)
    profile.tier = Theme.Text(card, 14, nil, nil, "OUTLINE")
    profile.tier:SetPoint("TOPLEFT", profile.sub, "BOTTOMLEFT", 0, -6)

    profile.rating = Theme.Text(card, 38, Theme.GOLD, Theme.TITLE_FONT, "OUTLINE")
    profile.rating:SetPoint("TOPRIGHT", -18, -10)
    profile.rating:SetJustifyH("RIGHT")
    local rl = Theme.Text(card, 10, Theme.MUTED)
    rl:SetPoint("TOPRIGHT", profile.rating, "BOTTOMRIGHT", 0, -2)
    rl:SetText("ELO RATING")

    -- Stat tiles along the bottom of the card.
    profile.stats = {}
    local labels = { "Peak", "Games", "W - L", "Win rate", "Opponents", "Rank" }
    for i, label in ipairs(labels) do
        local x = 90 + (i - 1) * 78
        local v = Theme.Text(card, 15, Theme.TEXT, nil, "OUTLINE")
        v:SetPoint("BOTTOMLEFT", x, 26)
        local l = Theme.Text(card, 10, Theme.MUTED)
        l:SetPoint("TOPLEFT", v, "BOTTOMLEFT", 0, -2)
        l:SetText(label:upper())
        profile.stats[i] = v
    end

    local gtitle = Theme.Text(page, 12, Theme.GOLD)
    gtitle:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 4, -10)
    gtitle:SetText("RATING PROGRESSION")
    local g = CreateFrame("Frame", nil, page, "BackdropTemplate")
    Theme.Panel(g, true)
    g:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -26)
    g:SetSize(430, 236)
    g.lines, g.labels = {}, {}
    for k = 1, 3 do
        local t = Theme.Text(g, 10, Theme.MUTED)
        t:SetJustifyH("RIGHT")
        g.labels[k] = t
    end
    g.empty = Theme.Text(g, 12, Theme.MUTED)
    g.empty:SetPoint("CENTER")
    g.empty:SetText("Play ranked duels to see your progression.")
    profile.graph = g

    local rtitle = Theme.Text(page, 12, Theme.GOLD)
    rtitle:SetPoint("TOPLEFT", g, "TOPRIGHT", 12, 16)
    rtitle:SetText("RECENT RANKED")
    local recent = CreateFrame("Frame", nil, page, "BackdropTemplate")
    Theme.Panel(recent, true)
    recent:SetPoint("TOPLEFT", g, "TOPRIGHT", 10, 0)
    recent:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    profile.recent = {}
    for i = 1, 10 do
        local t = Theme.Text(recent, 11)
        t:SetPoint("TOPLEFT", 10, -10 - (i - 1) * 22)
        t:SetPoint("RIGHT", recent, "RIGHT", -60, 0)
        local d = Theme.Text(recent, 11)
        d:SetPoint("TOPRIGHT", -10, -10 - (i - 1) * 22)
        d:SetJustifyH("RIGHT")
        profile.recent[i] = { t, d }
    end

    profile.back = Theme.Button(page, "My profile", 90, 20)
    profile.back:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 0, -28)
    profile.back:SetScript("OnClick", function() Main.ShowProfile(nil) end)
    profile.vouch = Theme.Text(page, 10, Theme.MUTED)
    profile.vouch:SetPoint("LEFT", profile.back, "RIGHT", 10, 0)
    profile.vouch:SetPoint("RIGHT", g, "RIGHT", 0, 0)
end

local function refreshProfile()
    local name = profile.viewing or ns.me.name
    local p = ns.players[name]
    if not p then
        if name == ns.me.name then p = ns.Me() else p = { name = name, r = Elo.START, g = 0, counted = 0, w = 0, l = 0, peak = Elo.START, hist = {}, nOpp = 0 } end
    end
    local class = p.class or (name == ns.me.name and ns.me.class)
    Theme.SetClassIcon(profile.icon, class)
    profile.name:SetText(name)
    profile.name:SetTextColor(Theme.ClassColor(class))
    local lvl = p.level or (name == ns.me.name and ns.me.level)
    profile.sub:SetText(string.format("Level %s %s", lvl or "?", classDisplay(class)))
    local tier = Theme.TierText(p.r, p.counted)
    local ranked = Ledger.IsRanked(p)
    profile.tier:SetText(tier .. (ranked and "" or string.format("  |cff9e9ea8(%d/%d games, %d/%d opponents to rank)|r",
        math.min(p.counted, Elo.PROVISIONAL_GAMES), Elo.PROVISIONAL_GAMES, math.min(p.nOpp, ns.RULES.MIN_OPPONENTS), ns.RULES.MIN_OPPONENTS)))
    profile.rating:SetText(p.r)
    local s = profile.stats
    s[1]:SetText(p.peak)
    s[2]:SetText(p.g)
    s[3]:SetText(string.format("|cff4ce65a%d|r - |cfff24d47%d|r", p.w, p.l))
    s[4]:SetText(winRate(p))
    s[5]:SetText(p.nOpp or 0)
    s[6]:SetText(p.rank and ("#" .. p.rank) or "-")
    drawGraph(profile.graph, p.hist)

    local shown = 0
    for i = #p.hist, 1, -1 do
        if shown >= #profile.recent then break end
        local h = p.hist[i]
        local r = ns.ledger:Get(h[4])
        if r then
            shown = shown + 1
            local side = Ledger.SideOf(r, name)
            local opp = side == "a" and r.b or r.a
            local oc = side == "a" and r.cb or r.ca
            local won = r.w == side
            local row = profile.recent[shown]
            row[1]:SetText((won and "|cff4ce65aW|r " or "|cfff24d47L|r ") .. Theme.ColorName(opp, oc))
            row[2]:SetText(Theme.Signed(h[3]))
        end
    end
    for i = shown + 1, #profile.recent do
        profile.recent[i][1]:SetText(i == 1 and "|cff9e9ea8No ranked games yet.|r" or "")
        profile.recent[i][2]:SetText("")
    end
    profile.back:SetShown(name ~= ns.me.name)
    local total = #p.hist
    profile.vouch:SetText(total > 0 and string.format("%d of %d matches confirmed by %s directly to you.",
        p.direct or 0, total, name == ns.me.name and "you" or "them") or "")
end

---------------------------------------------------------------------------
-- Leaderboard
---------------------------------------------------------------------------
local board = { classFilter = nil, search = "", showAll = false }

local function buildBoard(page)
    local search = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("TOPLEFT", 8, -2)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        board.search = (self:GetText() or ""):lower()
        Main.Refresh()
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local hint = Theme.Text(search, 11, Theme.MUTED)
    hint:SetPoint("LEFT", 2, 0)
    hint:SetText("Search player...")
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(self) hint:SetShown(self:GetText() == "") end)

    -- Class filter: All + one icon per class.
    local x = 190
    local function filterButton(class)
        local b = CreateFrame("Button", nil, page)
        b:SetSize(22, 22)
        b:SetPoint("TOPLEFT", x, -1)
        x = x + 25
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetAllPoints()
        if class then Theme.SetClassIcon(t, class) else
            t:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
            t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        local sel = b:CreateTexture(nil, "OVERLAY")
        sel:SetPoint("TOPLEFT", -2, 2); sel:SetPoint("BOTTOMRIGHT", 2, -2)
        sel:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.35)
        b.sel = sel
        b.class = class
        b:SetScript("OnClick", function() board.classFilter = class; Main.Refresh() end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(class and classDisplay(class) or "All classes")
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        board.filters[#board.filters + 1] = b
    end
    board.filters = {}
    filterButton(nil)
    for _, c in ipairs(CLASSES) do filterButton(c) end

    local all = Theme.Check(page, "Show unranked", function() return board.showAll end,
        function(v) board.showAll = v; Main.Refresh() end)
    all:SetPoint("TOPLEFT", x + 6, 0)

    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", 0, -30)
    header:SetPoint("TOPRIGHT", 0, -30)
    header:SetHeight(18)
    local cols = { { "#", 8 }, { "PLAYER", 50 }, { "TIER", 300 }, { "RATING", 420 }, { "W - L", 500 }, { "WIN %", 590 } }
    for _, c in ipairs(cols) do
        local t = Theme.Text(header, 10, Theme.GOLD)
        t:SetPoint("LEFT", c[2], 0)
        t:SetText(c[1])
    end
    Theme.Divider(page, -50, 0)

    board.list = makeList(page, 15, 22, function(row)
        row.rank = Theme.Text(row, 12, Theme.MUTED); row.rank:SetPoint("LEFT", 8, 0)
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(16, 16); row.icon:SetPoint("LEFT", 28, 0)
        row.name = Theme.Text(row, 12); row.name:SetPoint("LEFT", 50, 0); row.name:SetWidth(240)
        row.tier = Theme.Text(row, 12); row.tier:SetPoint("LEFT", 300, 0)
        row.rating = Theme.Text(row, 13, Theme.GOLD, nil, "OUTLINE"); row.rating:SetPoint("LEFT", 420, 0)
        row.wl = Theme.Text(row, 12); row.wl:SetPoint("LEFT", 500, 0)
        row.pct = Theme.Text(row, 12); row.pct:SetPoint("LEFT", 590, 0)
        row.me = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.me:SetAllPoints()
        row.me:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.10)
        row:SetScript("OnClick", function(self) if self.item then Main.ShowProfile(self.item.name) end end)
        row:SetScript("OnEnter", function(self)
            local p = self.item
            if not p then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(p.name, Theme.ClassColor(p.class))
            GameTooltip:AddDoubleLine("Peak", p.peak, 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("Last ranked game", p.last > 0 and date("%d %b %Y", p.last) or "-", 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("Confirmed to you directly", (p.direct or 0) .. " / " .. p.g, 0.7, 0.7, 0.7, 1, 1, 1)
            if (p.direct or 0) == 0 then
                GameTooltip:AddLine("Nobody has vouched for these results to you yet.", 1, 0.6, 0.2, true)
            end
            GameTooltip:AddLine("Click for profile", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end, function(row, p, index)
        row.rank:SetText(p.rank and p.rank or "-")
        Theme.SetClassIcon(row.icon, p.class)
        local mark = (p.direct or 0) == 0 and " |cffff9933?|r" or ""
        row.name:SetText(Theme.ColorName(p.name, p.class) .. mark)
        row.tier:SetText((Theme.TierText(p.r, p.counted)))
        row.rating:SetText(p.r)
        row.wl:SetText(string.format("|cff4ce65a%d|r - |cfff24d47%d|r", p.w, p.l))
        row.pct:SetText(winRate(p))
        row.me:SetShown(p.name == ns.me.name)
    end)
    board.list:SetPoint("TOPLEFT", 0, -54)
    board.list:SetPoint("BOTTOMRIGHT", 0, 22)

    board.footer = Theme.Text(page, 11, Theme.MUTED)
    board.footer:SetPoint("BOTTOMLEFT", 6, 2)
end

local function refreshBoard()
    for _, b in ipairs(board.filters) do b.sel:SetShown(b.class == board.classFilter) end
    local items, verified = {}, 0
    for _, p in ipairs(ns.board) do
        local ok = (board.showAll or Ledger.IsRanked(p))
            and (not board.classFilter or p.class == board.classFilter)
            and (board.search == "" or p.name:lower():find(board.search, 1, true))
            and not (ns.db.settings.hideUnvouched and (p.direct or 0) == 0 and p.name ~= ns.me.name)
        if ok then items[#items + 1] = p end
        verified = verified + p.g
    end
    board.list:SetItems(items)
    local me = ns.players[ns.me.name]
    board.footer:SetText(string.format("%d players shown  ·  %d verified matches  ·  Your rank: %s   |cffff9933?|r = no direct confirmation yet",
        #items, verified / 2, me and me.rank and ("#" .. me.rank) or "unranked"))
end

---------------------------------------------------------------------------
-- History (this character's duels, casual included)
---------------------------------------------------------------------------
local history = {}

local STATUS_TEXT = {
    verified = "|cff4ce65aVerified|r", pending = "|cffffd100Pending|r",
    disputed = "|cfff24d47Disputed|r", casual = "|cff9e9ea8Casual|r",
}

local function buildHistory(page)
    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(18)
    local cols = { { "DATE", 8 }, { "OPPONENT", 120 }, { "RESULT", 330 }, { "MODE", 400 }, { "CHANGE", 470 }, { "STATUS", 545 } }
    for _, c in ipairs(cols) do
        local t = Theme.Text(header, 10, Theme.GOLD)
        t:SetPoint("LEFT", c[2], 0)
        t:SetText(c[1])
    end
    Theme.Divider(page, -20, 0)
    history.list = makeList(page, 17, 22, function(row)
        row.date = Theme.Text(row, 11, Theme.MUTED); row.date:SetPoint("LEFT", 8, 0)
        row.opp = Theme.Text(row, 12); row.opp:SetPoint("LEFT", 120, 0); row.opp:SetWidth(200)
        row.res = Theme.Text(row, 12, nil, nil, "OUTLINE"); row.res:SetPoint("LEFT", 330, 0)
        row.mode = Theme.Text(row, 12); row.mode:SetPoint("LEFT", 400, 0)
        row.delta = Theme.Text(row, 12); row.delta:SetPoint("LEFT", 470, 0)
        row.status = Theme.Text(row, 12); row.status:SetPoint("LEFT", 545, 0)
        row:SetScript("OnClick", function(self) if self.item then Main.ShowProfile(self.item.opp) end end)
        row:SetScript("OnEnter", function(self)
            local e = self.item
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(e.opp)
            if e.how == "F" then GameTooltip:AddLine(e.result == "W" and "They fled" or "You fled", 0.8, 0.8, 0.8) end
            if e.secs then GameTooltip:AddDoubleLine("Duration", e.secs .. "s", 0.7, 0.7, 0.7, 1, 1, 1) end
            if e.zone then GameTooltip:AddDoubleLine("Zone", e.zone, 0.7, 0.7, 0.7, 1, 1, 1) end
            if e.evidence == "server" then
                GameTooltip:AddLine("Server statistics confirm this result.", 0.3, 0.9, 0.35, true)
            elseif e.evidence == "mismatch" then
                GameTooltip:AddLine("Server statistics did not match this result.", 1, 0.4, 0.3, true)
            end
            if e.match then GameTooltip:AddDoubleLine("Match id", e.match, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end, function(row, e)
        row.date:SetText(date("%d %b %H:%M", e.t))
        row.opp:SetText(Theme.ColorName(e.opp, e.class))
        row.res:SetText(e.result == "W" and "|cff4ce65aWIN|r" or "|cfff24d47LOSS|r")
        row.mode:SetText(e.mode == "R" and "|cffe6b422Ranked|r" or "Casual")
        local status = "casual"
        if e.mode == "R" and e.match then
            local r = ns.ledger:Get(e.match)
            status = r and Ledger.Status(r) or "pending"
        end
        local delta = ""
        if e.mode == "R" then
            local d = ns.deltas[e.match]
            if d and status == "verified" then
                local r = ns.ledger:Get(e.match)
                delta = Theme.Signed(Ledger.SideOf(r, ns.me.name) == "a" and d.da or d.db)
            elseif e.delta then
                delta = "|cff9e9ea8(" .. (e.delta >= 0 and "+" or "") .. e.delta .. ")|r"
            end
        end
        row.delta:SetText(delta)
        row.status:SetText(STATUS_TEXT[status] .. (e.evidence == "server" and " |cff4ce65a*|r" or ""))
    end)
    history.list:SetPoint("TOPLEFT", 0, -24)
    history.list:SetPoint("BOTTOMRIGHT", 0, 20)
    history.footer = Theme.Text(page, 11, Theme.MUTED)
    history.footer:SetPoint("BOTTOMLEFT", 6, 2)
end

local function refreshHistory()
    local src = ns.db.history[ns.me.name] or {}
    local items, w, l, cw, cl = {}, 0, 0, 0, 0
    for i = #src, 1, -1 do
        local e = src[i]
        items[#items + 1] = e
        if e.mode == "R" then
            if e.result == "W" then w = w + 1 else l = l + 1 end
        else
            if e.result == "W" then cw = cw + 1 else cl = cl + 1 end
        end
    end
    history.list:SetItems(items)
    history.footer:SetText(string.format("Ranked %d-%d  ·  Casual %d-%d  ·  |cff4ce65a*|r server statistics confirm the result", w, l, cw, cl))
end

---------------------------------------------------------------------------
-- Settings and network status
---------------------------------------------------------------------------
local settings = {}

local function buildSettings(page)
    local s = function() return ns.db.settings end
    local t = Theme.Text(page, 12, Theme.GOLD)
    t:SetPoint("TOPLEFT", 4, -4)
    t:SetText("WHEN SOMEONE DUELS YOU")
    local prefs = { { "ask", "Ask me each time" }, { "ranked", "Always ranked if possible" }, { "casual", "Always casual" } }
    settings.prefs = {}
    for i, p in ipairs(prefs) do
        local cb = Theme.Check(page, p[2], function() return s().pref == p[1] end, function()
            s().pref = p[1]
            for _, other in ipairs(settings.prefs) do other:SetChecked(s().pref == other.value) end
        end)
        cb.value = p[1]
        cb:SetPoint("TOPLEFT", 4, -20 - (i - 1) * 24)
        settings.prefs[i] = cb
    end

    local t2 = Theme.Text(page, 12, Theme.GOLD)
    t2:SetPoint("TOPLEFT", 4, -100)
    t2:SetText("DISPLAY & NETWORK")
    local opts = {
        { "resultScreen", "Show the victory / defeat screen" },
        { "chat", "Chat messages" },
        { "sound", "Sounds" },
        { "minimap", "Minimap button", function() ns.Minimap.Update() end },
        { "hideUnvouched", "Leaderboard: hide players nobody vouched for directly" },
        { "guildShare", "Sync with guild members" },
        { "directory", "Find other players via a hidden channel", function(v) if v then ns.Directory.Join() else ns.Directory.Leave() end end },
        { "bnet", "Sync with Battle.net friends on WoW Forever" },
        { "debug", "Debug output" },
    }
    for i, o in ipairs(opts) do
        local cb = Theme.Check(page, o[2], function() return s()[o[1]] end, function(v)
            s()[o[1]] = v
            if o[3] then o[3](v) end
            Main.Refresh()
        end)
        cb:SetPoint("TOPLEFT", 4, -116 - (i - 1) * 24)
    end

    local box = CreateFrame("Frame", nil, page, "BackdropTemplate")
    Theme.Panel(box, true)
    box:SetPoint("TOPLEFT", 360, 0)
    box:SetPoint("BOTTOMRIGHT", 0, 34)
    local bt = Theme.Text(box, 12, Theme.GOLD)
    bt:SetPoint("TOPLEFT", 10, -8)
    bt:SetText("NETWORK STATUS")
    settings.status = Theme.Text(box, 11)
    settings.status:SetPoint("TOPLEFT", 10, -28)
    settings.status:SetPoint("RIGHT", box, "RIGHT", -10, 0)
    settings.status:SetJustifyV("TOP")
    settings.status:SetSpacing(3)

    local sync = Theme.Button(page, "Sync now", 110, 22)
    sync:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 0, -28)
    sync:SetScript("OnClick", function()
        ns.Network.Announce()
        ns.Print("Inventory announced to guild/group; peers will sync.")
    end)
    local probe = Theme.Button(page, "Probe client", 110, 22)
    probe:SetPoint("LEFT", sync, "RIGHT", 8, 0)
    probe:SetScript("OnClick", function() ns.Commands.Run("probe") end)
end

local function refreshSettings()
    local v, p, d = 0, 0, 0
    for _, r in pairs(ns.ledger.store) do
        local st = Ledger.Status(r)
        if st == "verified" then v = v + 1 elseif st == "pending" then p = p + 1 else d = d + 1 end
    end
    local T, D = ns.Transport, ns.Directory
    local lines = {
        string.format("Version %s  ·  protocol %d  ·  season %d", ns.VERSION, ns.PROTO, ns.SEASON),
        string.format("Matches: |cff4ce65a%d verified|r, |cffffd100%d pending|r, |cfff24d47%d disputed|r", v, p, d),
        string.format("Peers heard (30 min): %d  ·  known: %d", ns.Network.PeerCount(1800), ns.Network.PeerCount(30 * 86400)),
        string.format("Directory: %s (%d names)", D.state or "?", #D.names),
        string.format("Messages: %d sent, %d received, %d refused", T.stats.sent, T.stats.recv, T.stats.refused),
        string.format("Send queue: %d", T.QueueSize()),
        string.format("Conflicting copies ignored: %d", ns.ledger.conflicts),
        string.format("Server duel statistics: %s", ns.Evidence.Supported() and "|cff4ce65aavailable|r" or "|cff9e9ea8not available|r"),
    }
    settings.status:SetText(table.concat(lines, "\n"))
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local REFRESH = { profile = refreshProfile, board = refreshBoard, history = refreshHistory, settings = refreshSettings }

local function selectTab(key)
    activeTab = key
    for k, page in pairs(pages) do page:SetShown(k == key) end
    for _, t in ipairs(tabs) do
        if t.key == key then
            t.text:SetTextColor(1, 1, 1)
            t.bar:Show()
        else
            t.text:SetTextColor(Theme.GOLD_DIM[1] + 0.2, Theme.GOLD_DIM[2] + 0.2, Theme.GOLD_DIM[3] + 0.1)
            t.bar:Hide()
        end
    end
    Main.Refresh()
end

local function build()
    f = CreateFrame("Frame", "DuelLadderFrame", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        ns.db.ui.main = { point, rel, x, y }
    end)
    local pos = ns.db.ui.main
    if type(pos) == "table" and pos[1] then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else f:SetPoint("CENTER") end
    Theme.Panel(f)
    tinsert(UISpecialFrames, "DuelLadderFrame")
    f:Hide()

    local swords = f:CreateTexture(nil, "ARTWORK")
    swords:SetSize(28, 28)
    swords:SetPoint("TOPLEFT", 18, -14)
    swords:SetTexture("Interface\\Icons\\Ability_DualWield")
    swords:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local title = Theme.Title(f, 24)
    title:SetPoint("LEFT", swords, "RIGHT", 8, -1)
    title:SetText("Duel Ladder")
    local sub = Theme.Text(f, 11, Theme.MUTED)
    sub:SetPoint("LEFT", title, "RIGHT", 10, -3)
    sub:SetText("Season " .. ns.SEASON .. "  ·  ranked duels for WoW Forever")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local defs = { { "profile", "Profile" }, { "board", "Leaderboard" }, { "history", "History" }, { "settings", "Settings" } }
    local x = 20
    for _, d in ipairs(defs) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(110, 26)
        b:SetPoint("TOPLEFT", x, -50)
        x = x + 114
        b.text = Theme.Title(b, 15)
        b.text:SetPoint("CENTER")
        b.text:SetText(d[2])
        b.bar = b:CreateTexture(nil, "ARTWORK")
        b.bar:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.9)
        b.bar:SetHeight(2)
        b.bar:SetPoint("BOTTOMLEFT", 8, 0)
        b.bar:SetPoint("BOTTOMRIGHT", -8, 0)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        b.key = d[1]
        b:SetScript("OnClick", function() selectTab(d[1]) end)
        tabs[#tabs + 1] = b
    end
    Theme.Divider(f, -78, 16)

    for _, d in ipairs(defs) do
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", 20, -88)
        page:SetPoint("BOTTOMRIGHT", -20, 18)
        page:Hide()
        pages[d[1]] = page
    end
    buildProfile(pages.profile)
    buildBoard(pages.board)
    buildHistory(pages.history)
    buildSettings(pages.settings)

    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed > 2 and activeTab == "settings" then elapsed = 0; refreshSettings() end
    end)
    selectTab(activeTab)
end

function Main.Refresh()
    if not f or not f:IsShown() then return end
    local fn = REFRESH[activeTab]
    if fn then fn() end
end

function Main.Show(tab)
    if not ns.ledger then return end
    if not f then build() end
    f:Show()
    selectTab(tab or activeTab)
end

function Main.Toggle(tab)
    if f and f:IsShown() and (not tab or tab == activeTab) then f:Hide() else Main.Show(tab) end
end

function Main.ShowProfile(name)
    profile.viewing = name
    Main.Show("profile")
end

ns.Listen(function(event)
    if event == "LEDGER" or event == "HISTORY" or event == "RESULT" or event == "STATUS" then Main.Refresh() end
end)

return Main
