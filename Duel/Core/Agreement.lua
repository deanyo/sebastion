-- Agreement.lua: the Ranked / Casual handshake between two clients for one duel.
-- Pure logic: every effect goes through `deps`, so tests can wire two engines together.
--
-- Flow (all messages are whispers between the two duellists):
--   1. Both sides see the duel request (challenger: StartDuel hook; challenged:
--      DUEL_REQUESTED) and call Begin(), which sends HELLO with a fresh nonce.
--   2. Each side decides (prompt, or automatic preference) and sends CONSENT.
--   3. The challenged side LOCKS when the countdown starts (or shortly after it
--      accepts): ranked only if both consented, both are eligible and both run a
--      compatible protocol. It sends LOCK; the challenger adopts it. A challenger
--      that never receives LOCK stays casual - the match then lacks its second
--      attestation and can never become verified, so no rating moves.
--   4. Finish() returns the locked mode and the match id (from both nonces).
--
-- Messages ("~"-separated, nonces tie replies to this duel):
--   H~proto~version~nonce~role~level~class~rating~games
--   R~theirNonce~1|0~reason
--   L~theirNonce~R|C
local _, ns = ...
local Util, Ledger = ns.Util, ns.Ledger

local Agreement = {}
ns.Agreement = Agreement

Agreement.HELLO_TTL = 30       -- keep a HELLO that arrives before our own duel event
Agreement.STALE = 180          -- forget an unlocked session after this long
Agreement.LOCKED_MAX = 900     -- and a locked one (a duel never lasts this long)

local Engine = {}
Engine.__index = Engine

-- deps:
--   send(target, msg)          whisper an addon message
--   now()                      seconds (monotonic)
--   nonce()                    short unique token
--   myName()                   our canonical name
--   me()                       { level, class, rating, games }
--   pref()                     "ask" | "ranked" | "casual"
--   eligible(opp, peer)        -> ok, reason   (levels, own alts, ...)
--   onChange(session)          redraw the prompt (session may be nil)
--   onNewerVersion(version)    optional
function Agreement.New(deps)
    return setmetatable({ deps = deps, stash = {}, session = nil }, Engine)
end

local function encodeHello(s, me)
    return table.concat({ "H", ns.PROTO, ns.VERSION, s.nonce, s.role, me.level or 0,
        me.class or "", me.rating or 0, me.games or 0 }, "~")
end

local function parseHello(f)
    local proto = Util.Int(f[2], 0, 1000)
    local nonce = f[4]
    if not proto or type(nonce) ~= "string" or not nonce:match("^[0-9a-z]+$") or #nonce > 16 then return nil end
    return {
        proto = proto, version = f[3], nonce = nonce,
        role = (f[5] == "C" or f[5] == "D") and f[5] or nil,
        level = Util.Int(f[6], 0, 200), class = Util.ClassToken(f[7]),
        rating = Util.Int(f[8], 0, 5000), games = Util.Int(f[9], 0, 1000000),
    }
end

function Engine:_changed()
    if self.deps.onChange then self.deps.onChange(self.session) end
end

function Engine:_expire()
    local now = self.deps.now()
    local s = self.session
    if s then
        local limit = s.locked and Agreement.LOCKED_MAX or Agreement.STALE
        if now - s.startedAt > limit then self.session = nil end
    end
    for name, st in pairs(self.stash) do
        if now - st.t > Agreement.HELLO_TTL then self.stash[name] = nil end
    end
end

function Engine:Session() self:_expire(); return self.session end

-- A duel request involving us. role: "C" we challenged, "D" we were challenged.
function Engine:Begin(opp, role)
    self:_expire()
    local s = self.session
    if s and s.opp == opp and not s.finished then return s end
    s = { opp = opp, role = role, nonce = self.deps.nonce(), startedAt = self.deps.now() }
    self.session = s
    self.deps.send(opp, encodeHello(s, self.deps.me()))
    local early = self.stash[opp]
    self.stash[opp] = nil
    if early then self:_onHello(s, early.hello) end
    self:_changed()
    return s
end

function Engine:_onHello(s, hello)
    s.peer, s.theirNonce = hello, hello.nonce
    if hello.proto ~= ns.PROTO then
        s.eligible, s.reason = false, hello.proto > ns.PROTO and "they_newer" or "they_older"
        if hello.proto > ns.PROTO and self.deps.onNewerVersion then self.deps.onNewerVersion(hello.version) end
    else
        local ok, reason = true, nil
        if self.deps.eligible then ok, reason = self.deps.eligible(s.opp, hello) end
        s.eligible, s.reason = ok and true or false, reason
    end
    if s.myConsent == nil then
        local pref = self.deps.pref and self.deps.pref() or "ask"
        if not s.eligible or pref == "casual" then
            self:Consent(false, true)
        elseif pref == "ranked" then
            self:Consent(true, true)
        end
    elseif s.consentQueued then
        s.consentQueued = nil
        self:_sendConsent(s)
    end
end

function Engine:_sendConsent(s)
    self.deps.send(s.opp, table.concat({ "R", s.theirNonce, s.myConsent and "1" or "0", s.reason or "" }, "~"))
end

-- Our answer to the prompt. auto: decided by preference/eligibility.
function Engine:Consent(value, auto)
    local s = self:Session()
    if not s or s.locked then return false end
    if value and s.eligible == false then value = false end
    s.myConsent, s.autoConsent = value and true or false, auto and true or nil
    if s.theirNonce then self:_sendConsent(s) else s.consentQueued = true end
    if not auto then self:_changed() end
    return true
end

-- The challenged side decides the mode; the challenger waits for its LOCK.
function Engine:Lock()
    local s = self:Session()
    if not s or s.locked then return s and s.locked end
    if s.role ~= "D" then
        s.lockRequested = true
        return nil
    end
    local ranked = s.myConsent == true and s.theirConsent == true and s.eligible == true
        and s.peer ~= nil
    s.locked = ranked and "R" or "C"
    if not ranked then
        -- Why casual, for the screen.
        if not s.peer then s.lockReason = "no_addon"
        elseif s.eligible ~= true then s.lockReason = "ineligible"
        elseif s.myConsent ~= true then s.lockReason = s.myConsent == false and "you" or "you_slow"
        elseif s.theirConsent == false then s.lockReason = "they"
        else s.lockReason = "they_slow" end
    end
    if s.theirNonce then
        self.deps.send(s.opp, table.concat({ "L", s.theirNonce, s.locked }, "~"))
    end
    self:_changed()
    return s.locked
end

-- Returns true when the message belonged to the handshake.
function Engine:OnMessage(sender, text)
    local kind = text:sub(1, 2)
    if kind ~= "H~" and kind ~= "R~" and kind ~= "L~" then return false end
    self:_expire()
    local f = Util.Split(text, "~")
    local s = self.session
    if f[1] == "H" then
        local hello = parseHello(f)
        if not hello then return true end
        if s and s.opp == sender and not s.finished then
            self:_onHello(s, hello)
            self:_changed()
        else
            self.stash[sender] = { hello = hello, t = self.deps.now() }
        end
        return true
    end
    if not s or s.opp ~= sender or f[2] ~= s.nonce then return true end
    if f[1] == "R" then
        if s.locked then return true end
        s.theirConsent = f[3] == "1"
        s.theirReason = f[4] ~= "" and f[4] or nil
        self:_changed()
    elseif f[1] == "L" and s.role == "C" and not s.locked then
        local ranked = f[3] == "R" and s.myConsent == true and s.eligible == true
        s.locked = ranked and "R" or "C"
        if not ranked then
            if s.eligible ~= true then s.lockReason = "ineligible"
            elseif s.myConsent ~= true then s.lockReason = s.myConsent == false and "you" or "you_slow"
            elseif s.theirConsent == false then s.lockReason = "they"
            else s.lockReason = "they_slow" end
        end
        self:_changed()
    end
    return true
end

-- The duel produced a result. Returns { ranked, matchId, opp, peer } and closes the session.
function Engine:Finish(opp)
    local s = self:Session()
    if not s or s.opp ~= opp then return { ranked = false, opp = opp } end
    s.finished = true
    self.session = nil
    local ranked = s.locked == "R" and s.peer ~= nil and s.theirNonce ~= nil
    local out = { ranked = ranked, opp = opp, peer = s.peer, mode = s.locked or "C" }
    if s.theirNonce then
        out.matchId = Ledger.MatchId(self.deps.myName(), opp, s.nonce, s.theirNonce)
    end
    self:_changed()
    return out
end

function Engine:Cancel()
    if self.session then
        self.session = nil
        self:_changed()
    end
end

return Agreement
