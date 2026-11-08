-- Minimal WoW API stub: enough to load and drive the whole addon headless.
-- Set before loading: ME_NAME, ME_CLASS, ME_LEVEL, NOW (server epoch), SEND(prefix,msg,type,target)
local clock = 0
local timers = {}
local frames = {}
UNITS = { player = { name = ME_NAME, class = ME_CLASS, level = ME_LEVEL } }

local mockMT
local function mock()
    return setmetatable({ _shown = false, _scripts = {}, _events = {} }, mockMT)
end
mockMT = {
    __index = function(t, k)
        local fns = {
            IsShown = function(self) return self._shown end,
            Show = function(self) self._shown = true end,
            Hide = function(self) self._shown = false end,
            SetShown = function(self, v) self._shown = v and true or false end,
            SetScript = function(self, name, fn) self._scripts[name] = fn end,
            GetScript = function(self, name) return self._scripts[name] end,
            RegisterEvent = function(self, e) self._events[e] = true end,
            RegisterUnitEvent = function(self, e) self._events[e] = true end,
            UnregisterEvent = function(self, e) self._events[e] = nil end,
            GetWidth = function() return 400 end, GetHeight = function() return 236 end,
            GetText = function() return "" end, GetChecked = function() return false end,
            GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
            GetCenter = function() return 100, 100 end,
            GetEffectiveScale = function() return 1 end,
            GetThumbTexture = function() return mock() end,
            CreateTexture = function() return mock() end,
            CreateFontString = function() return mock() end,
            CreateLine = function() return mock() end,
            GetNumPoints = function() return 0 end,
        }
        if fns[k] then return fns[k] end
        return function() return nil end
    end,
}

function CreateFrame(kind, name, parent, template)
    local f = mock()
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
UIParent, Minimap, DEFAULT_CHAT_FRAME = mock(), mock(), mock()
DEFAULT_CHAT_FRAME.AddMessage = function(_, msg) PRINTED[#PRINTED + 1] = msg end
PRINTED = {}
GameTooltip = mock()
UISpecialFrames = {}
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
RAID_CLASS_COLORS = {}
CLASS_ICON_TCOORDS = {}
SlashCmdList = { DUEL = function(msg) BLIZZARD_DUEL = msg end }
hash_SlashCmdList = {}
NUM_CHAT_WINDOWS = 1
DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
DUEL_COUNTDOWN = "Duel starting: %d"
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
WOW_PROJECT_ID = 1
SOUNDKIT = {}

function tinsert(t, v) t[#t + 1] = v end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strsplit(sep, s) return s end
function date(fmt, t) return os.date(fmt, t) end
time = os.time
function GetTime() return clock end
function GetServerTime() return NOW + math.floor(clock) end
function securecall(fn, ...) return fn(...) end
function geterrorhandler() return function(e) error(e) end end
function hooksecurefunc(name, hook)
    local orig = _G[name]
    _G[name] = function(...) local r = orig(...); hook(...); return r end
end
function GetBuildInfo() return "1.60.1", "70862", "Nov 2026", 16001 end
function InCombatLockdown() return false end
function IsInInstance() return false, "none" end
function IsInGroup() return false end
function IsInRaid() return false end
function IsInGuild() return false end
function UnitInRaid() return nil end
function UnitExists(u) return UNITS[u] ~= nil end
function UnitIsPlayer(u) return UNITS[u] ~= nil end
function UnitName(u) return UNITS[u] and UNITS[u].name end
function GetUnitName(u) return UNITS[u] and UNITS[u].name end
function UnitGUID(u) return nil end
function UnitClass(u) local x = UNITS[u]; if x then return x.class, x.class end end
function UnitLevel(u) return UNITS[u] and UNITS[u].level or 0 end
function UnitHealth() return 100 end
function UnitIsUnit() return false end
function GetRealZoneText() return "Elwynn Forest" end
function GetChannelName() return 0 end
function JoinTemporaryChannel() end
function LeaveChannelByName() end
function ChatFrame_AddMessageEventFilter(event, fn) FILTERS = FILTERS or {}; FILTERS[event] = fn end
function ChatFrame_RemoveChannel() end
function PlaySound() end
function UIFrameFadeIn(f) f:Show() end
function UIFrameFadeOut() end
function GameTooltip_Hide() end
function BNGetNumFriends() return 0 end
function StartDuel(arg) STARTED = arg end
function AcceptDuel() end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(prefix, msg, chatType, target) return SEND(prefix, msg, chatType, target) end,
}
C_BattleNet = {}

local function schedule(sec, fn, ticker)
    local t = { at = clock + sec, fn = fn, every = ticker and sec or nil }
    function t:Cancel() self.cancelled = true end
    timers[#timers + 1] = t
    return t
end
C_Timer = {
    After = function(sec, fn) schedule(sec, fn) end,
    NewTimer = function(sec, fn) return schedule(sec, fn) end,
    NewTicker = function(sec, fn) return schedule(sec, fn, true) end,
}

function ADVANCE(sec)
    local target = clock + sec
    while true do
        local best
        for _, t in ipairs(timers) do
            if not t.cancelled and t.at <= target and (not best or t.at < best.at) then best = t end
        end
        if not best then break end
        clock = math.max(clock, best.at)
        if best.every then best.at = best.at + best.every else best.cancelled = true end
        best.fn(best)
    end
    clock = target
    local live = {}
    for _, t in ipairs(timers) do if not t.cancelled then live[#live + 1] = t end end
    timers = live
end

function FIRE(event, ...)
    for _, f in ipairs(frames) do
        local h = f._scripts.OnEvent
        if f._events[event] and h then h(f, event, ...) end
    end
end

function SYSTEM(msg)
    local filter = FILTERS and FILTERS.CHAT_MSG_SYSTEM
    if filter and filter(nil, "CHAT_MSG_SYSTEM", msg) then return end
    FIRE("CHAT_MSG_SYSTEM", msg)
end

function LOAD_ADDON(root, files)
    local ns = {}
    for _, file in ipairs(files) do
        local chunk = assert(loadfile(root .. "/Duel/" .. file))
        chunk("Duel", ns)
    end
    ADDON_NS = ns
    return ns
end
