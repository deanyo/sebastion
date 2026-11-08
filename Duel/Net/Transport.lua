-- Transport.lua: addon-message I/O with throttling. The only file that calls
-- C_ChatInfo.SendAddonMessage / C_BattleNet.SendGameData.
--
-- WoW Forever facts this follows (measured by Overlord's author, 2026-09/11):
--   * Custom-channel addon messages are refused by the server since launch.
--   * Group/raid/guild/channel share ~1 message/s per prefix; bursts are refused.
--   * Whispers have their own, larger budget and cross realms by "First Last".
--   * A whisper to an offline name prints "No player named ..." in chat: we hide
--     those for names we addressed in the last seconds.
local _, ns = ...
local Util = ns.Util

local T = { stats = { sent = 0, refused = 0, recv = 0, dropped = 0 } }
ns.Transport = T

-- Token buckets per lane: rate (msgs/s) and burst.
local LANES = {
    WHISPER = { rate = 3, burst = 6 },
    SHARED  = { rate = 0.7, burst = 1 },   -- PARTY / RAID / GUILD / CHANNEL
    BNET    = { rate = 2, burst = 4 },
}
local GUILD_MIN_GAP = 10                  -- extra spacing between our guild messages
local QUEUE_MAX = 400

local queues = { WHISPER = {}, SHARED = {}, BNET = {} }
local tokens, tokensAt = {}, {}
local lastGuildAt = -1000
local recentWhispers = {}                 -- lowercased target -> GetTime()
local frame = CreateFrame("Frame")

local function laneOf(chatType)
    if chatType == "WHISPER" then return "WHISPER" end
    if chatType == "BNET" then return "BNET" end
    return "SHARED"
end

local function take(lane)
    local cfg, now = LANES[lane], GetTime()
    local t = math.min(cfg.burst, (tokens[lane] or cfg.burst) + (now - (tokensAt[lane] or now)) * cfg.rate)
    tokensAt[lane] = now
    if t < 1 then tokens[lane] = t; return false end
    tokens[lane] = t - 1
    return true
end

function T.Readable(v)
    if v == nil then return false end
    if canaccessvalue and not canaccessvalue(v) then return false end
    if issecretvalue and issecretvalue(v) then return false end
    return true
end

local function inRestrictedInstance()
    local inside, kind = IsInInstance()
    return inside and (kind == "pvp" or kind == "arena")
end

local function rawSend(item)
    if item.chatType == "BNET" then
        if not (C_BattleNet and C_BattleNet.SendGameData) then return true end
        securecall(C_BattleNet.SendGameData, item.target, ns.PREFIX, item.msg)
        return true
    end
    if item.chatType == "WHISPER" then
        recentWhispers[item.target:lower()] = GetTime()
    end
    local result = securecall(C_ChatInfo.SendAddonMessage, ns.PREFIX, item.msg, item.chatType, item.target)
    -- Enum.SendAddonMessageResult: 0 = success; older clients return a boolean.
    return result == nil or result == true or result == 0, result
end

local function pump()
    if inRestrictedInstance() then return end
    for lane, q in pairs(queues) do
        while q[1] do
            local item = q[1]
            if item.chatType == "GUILD" and GetTime() - lastGuildAt < GUILD_MIN_GAP then break end
            if not take(lane) then break end
            table.remove(q, 1)
            local ok, code = rawSend(item)
            if ok then
                T.stats.sent = T.stats.sent + 1
                if item.chatType == "GUILD" then lastGuildAt = GetTime() end
                ns.Debug("> %s %s %s", item.chatType, tostring(item.target or ""), item.msg:sub(1, 60))
            else
                T.stats.refused = T.stats.refused + 1
                T.lastRefusal = code
                item.tries = (item.tries or 0) + 1
                if item.tries < 3 then
                    table.insert(q, 1, item)
                    tokens[lane] = -1   -- back off a little
                end
                break
            end
        end
    end
end

-- Queue a message. chatType: WHISPER | PARTY | RAID | GUILD | CHANNEL | BNET.
-- target: name (WHISPER), channel number (CHANNEL), gameAccountID (BNET).
-- urgent: put at the head of its lane (handshake messages).
function T.Send(msg, chatType, target, urgent)
    if type(msg) ~= "string" or #msg > 255 then return false end
    if chatType == "WHISPER" and (type(target) ~= "string" or not Util.CanonName(target)) then return false end
    local q = queues[laneOf(chatType)]
    if #q >= QUEUE_MAX then T.stats.dropped = T.stats.dropped + 1; return false end
    local item = { msg = msg, chatType = chatType, target = target }
    if urgent then table.insert(q, 1, item) else q[#q + 1] = item end
    pump()
    return true
end

function T.QueueSize()
    return #queues.WHISPER + #queues.SHARED + #queues.BNET
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
T.handlers = {}   -- fn(text, channel, sender, bnetId)

local function deliver(text, channel, sender, bnetId)
    T.stats.recv = T.stats.recv + 1
    for _, fn in ipairs(T.handlers) do
        local ok, err = pcall(fn, text, channel, sender, bnetId)
        if not ok then ns.Debug("handler error: %s", tostring(err)) end
    end
end

local function bnetSender(gameAccountID)
    if not (C_BattleNet and C_BattleNet.GetGameAccountInfoByID) then return nil end
    local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, gameAccountID)
    if not ok or not info or info.clientProgram ~= "WoW" then return nil end
    if info.isInCurrentRegion == false then return nil end
    -- Battle.net reports WoW Forever as project 18.
    if info.wowProjectID and info.wowProjectID ~= 18 and info.wowProjectID ~= WOW_PROJECT_ID then return nil end
    return Util.CanonName(info.characterName)
end

frame:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
    if event == "CHAT_MSG_ADDON" then
        if not T.Readable(prefix) or prefix ~= ns.PREFIX then return end
        if not T.Readable(text) or not T.Readable(sender) then return end
        if inRestrictedInstance() then return end
        local name = Util.CanonName(sender)
        if not name or name == ns.me.name then return end
        deliver(text, channel, name)
    elseif event == "BN_CHAT_MSG_ADDON" then
        if not T.Readable(prefix) or prefix ~= ns.PREFIX or not T.Readable(text) then return end
        -- BN_CHAT_MSG_ADDON: prefix, text, channel, senderGameAccountID
        local gameAccountID = sender
        local name = bnetSender(gameAccountID)
        if not name or name == ns.me.name then return end
        deliver(text, "BNET", name, gameAccountID)
    end
end)

function T.Start()
    C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("BN_CHAT_MSG_ADDON")
    C_Timer.NewTicker(0.25, pump)
end

---------------------------------------------------------------------------
-- "No player named X is currently playing." for our own addon whispers
---------------------------------------------------------------------------
local notFoundPattern
do
    local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
    local p = fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
    notFoundPattern = "^" .. p .. "$"
end

T.onUnreachable = nil   -- fn(name)

local function systemFilter(_, _, msg, ...)
    if not T.Readable(msg) or type(msg) ~= "string" then return false end
    local who = msg:match(notFoundPattern)
    if not who then return false end
    local key = Util.CanonName(who)
    key = key and key:lower()
    local at = key and recentWhispers[key]
    if at and GetTime() - at < 15 then
        if T.onUnreachable then pcall(T.onUnreachable, Util.CanonName(who)) end
        return true
    end
    return false
end

if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
end

return T
