-- Directory.lua: find other Duel users through a hidden chat channel's member list.
--
-- WoW Forever refuses addon messages on custom channels, but a channel still has
-- a member list that any member can read (technique proven by Overlord 2.2.0).
-- Every Duel user joins the same hidden channel; we read its members and greet a
-- few of them by whisper. Whoever answers becomes a sync peer.
-- The game only loads a channel's member list when that channel becomes the one
-- selected for display, so we briefly select another channel and then ours -
-- never in combat and never while the game's channel window is open.
local _, ns = ...
local Util = ns.Util

local D = { names = {}, state = "idle", stats = { reads = 0, greeted = 0 } }
ns.Directory = D

D.CHANNEL = "DuelLadderF"
D.JOIN_DELAY = 40         -- after login, so General/Trade keep their numbers
D.REFRESH = 600
D.MAX_NAMES = 1000

local function inCombat() return InCombatLockdown and InCombatLockdown() end
local function windowOpen()
    local f = _G.ChannelFrame
    return f and f.IsShown and f:IsShown()
end

function D.ChannelId()
    local id = GetChannelName(D.CHANNEL)
    if type(id) == "number" and id > 0 and ns.Transport.Readable(id) then return id end
    return nil
end

local function hideFromChatFrames()
    if not (ChatFrame_RemoveChannel and NUM_CHAT_WINDOWS) then return end
    for i = 1, NUM_CHAT_WINDOWS do
        local cf = _G["ChatFrame" .. i]
        if cf then pcall(ChatFrame_RemoveChannel, cf, D.CHANNEL) end
    end
end

-- Swallow join/leave notices for our channel.
local function noticeFilter(_, _, ...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and ns.Transport.Readable(v) and v:find(D.CHANNEL, 1, true) then return true end
    end
    return false
end
if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", noticeFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", noticeFilter)
end

local function scan()
    if type(GetChannelDisplayInfo) ~= "function" then return nil end
    local n = (GetNumDisplayChannels and GetNumDisplayChannels()) or 40
    local ours, members, other
    for i = 1, math.min(n, 60) do
        local ok, name, isHeader, _, _, count = pcall(GetChannelDisplayInfo, i)
        if ok and ns.Transport.Readable(name) and type(name) == "string" and not isHeader then
            if name:lower() == D.CHANNEL:lower() then
                ours, members = i, tonumber(count)
            elseif not other then
                other = i
            end
        end
    end
    return ours, members, other
end

local function read(index, members)
    if not (C_ChatInfo and C_ChatInfo.GetChannelRosterInfo) then return false end
    local names = {}
    for k = 1, math.min(members, D.MAX_NAMES) do
        local ok, name = pcall(C_ChatInfo.GetChannelRosterInfo, index, k)
        local canon = ok and ns.Transport.Readable(name) and Util.CanonName(name)
        if canon and canon ~= ns.me.name then names[#names + 1] = canon end
    end
    D.names, D.readAt, D.state = names, GetTime(), "ok"
    D.stats.reads = D.stats.reads + 1
    return true
end

function D.Refresh()
    if not ns.db.settings.directory or inCombat() or windowOpen() then return end
    local ours, members, other = scan()
    if not ours then D.state = "not in channel"; return end
    if members and members > 0 then return read(ours, members) end
    if not (other and SetSelectedDisplayChannel) then D.state = "list not loaded"; return end
    pcall(SetSelectedDisplayChannel, other)
    pcall(SetSelectedDisplayChannel, ours)
    D.state = "fetching"
    for _, delay in ipairs({ 3, 8 }) do
        C_Timer.After(delay, function()
            if D.state ~= "fetching" or inCombat() then return end
            local o, m = scan()
            if o and m and m > 0 then read(o, m) end
        end)
    end
end

function D.Join()
    if not ns.db.settings.directory then return end
    if D.ChannelId() then hideFromChatFrames(); return end
    if JoinTemporaryChannel then securecall(JoinTemporaryChannel, D.CHANNEL, nil, 0) end
    C_Timer.After(3, function()
        hideFromChatFrames()
        D.Refresh()
    end)
end

function D.Leave()
    if D.ChannelId() and LeaveChannelByName then pcall(LeaveChannelByName, D.CHANNEL) end
    D.names = {}
end

-- A random listed name we have not heard from, or nil.
function D.Candidate(isKnown)
    local n = #D.names
    if n == 0 then return nil end
    for _ = 1, 8 do
        local name = D.names[math.random(1, n)]
        if not isKnown(name) then return name end
    end
    return nil
end

function D.Start()
    C_Timer.After(D.JOIN_DELAY, D.Join)
    C_Timer.NewTicker(D.REFRESH, function()
        if not D.ChannelId() then D.Join() else D.Refresh() end
    end)
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGOUT")
    f:SetScript("OnEvent", function()
        -- Leave so the game never rejoins it at login ahead of General/Trade.
        if D.ChannelId() and LeaveChannelByName then pcall(LeaveChannelByName, D.CHANNEL) end
    end)
end

return D
