-- SyncProto.lua: anti-entropy between two peers' ledgers. Pure logic.
--
-- Every record is shared (pending ones too: the second attestation must be able
-- to find the first). Two peers compare cheaply, then narrow down:
--   SI~proto~count~root~version  inventory: record count + order-free hash of all ids
--   SD                           "send me your day buckets"
--   SB~d:n:h,d:n:h,...           day buckets (day index base36, count, hash) - chunked
--   SBE                          end of buckets
--   SL~day                       "send me the ids of that day"
--   SLI~day~id,id,...            ids (chunked)            SLE~day   end of ids
--   SG~id,id,...                 "send me these records" -> M~... lines
-- A record that changed confirmation state changes the hash too (the id's hash is
-- salted with the confirmation flags), so a newly verified record syncs again.
local _, ns = ...
local Util = ns.Util

local Sync = {}
ns.SyncProto = Sync

local M32 = 4294967296
Sync.MAX_LINE = 240
Sync.MAX_IDS_PER_GET = 18

-- Hash of one record's id and the claim flags we would share for it.
function Sync.Flags(r)
    local cf = r.cf or {}
    return ((cf.a or 0) > 0 and 1 or 0) + ((cf.b or 0) > 0 and 2 or 0)
end

function Sync.RecordHash(r)
    return Util.Hash32(r.id .. Sync.Flags(r), 7919)
end

function Sync.Day(ts) return math.floor(ts / 86400) end

-- { count, root, days = { [day] = { n, h, ids = {...} } } }
function Sync.Summarize(store)
    local count, root, days = 0, 0, {}
    for id, r in pairs(store) do
        local h = Sync.RecordHash(r)
        count = count + 1
        root = (root + h) % M32
        local d = Sync.Day(r.ts)
        local b = days[d]
        if not b then b = { n = 0, h = 0, ids = {} }; days[d] = b end
        b.n = b.n + 1
        b.h = (b.h + h) % M32
        b.ids[#b.ids + 1] = id .. Sync.Flags(r)
    end
    return { count = count, root = root, days = days }
end

function Sync.EncodeInventory(sum)
    return table.concat({ "SI", ns.PROTO, sum.count, Util.Base36(sum.root), ns.VERSION }, "~")
end

function Sync.DecodeInventory(text)
    local f = Util.Split(text, "~")
    if f[1] ~= "SI" then return nil end
    local proto, count, root = Util.Int(f[2], 0, 1000), Util.Int(f[3], 0, 10000000), Util.FromBase36(f[4] or "")
    if not proto or not count or not root then return nil end
    local version = f[5] and f[5]:match("^%d+%.%d+%.%d+$") or nil
    return { proto = proto, count = count, root = root, version = version }
end

function Sync.Same(a, b) return a.count == b.count and a.root == b.root end

-- Lines of at most MAX_LINE bytes: prefix .. item,item,...
function Sync.Chunk(prefix, items)
    local lines, cur = {}, nil
    for _, it in ipairs(items) do
        if cur and #cur + 1 + #it > Sync.MAX_LINE then
            lines[#lines + 1] = cur
            cur = nil
        end
        cur = cur and (cur .. "," .. it) or (prefix .. it)
    end
    if cur then lines[#lines + 1] = cur end
    return lines
end

function Sync.EncodeBuckets(sum)
    local items, sorted = {}, {}
    for d in pairs(sum.days) do sorted[#sorted + 1] = d end
    table.sort(sorted)
    for _, d in ipairs(sorted) do
        local b = sum.days[d]
        items[#items + 1] = Util.Base36(d) .. ":" .. b.n .. ":" .. Util.Base36(b.h)
    end
    local lines = Sync.Chunk("SB~", items)
    lines[#lines + 1] = "SBE"
    return lines
end

-- Parse one SB line into out[day] = { n, h }.
function Sync.DecodeBuckets(text, out)
    local body = text:match("^SB~(.*)$")
    if not body then return false end
    for _, item in ipairs(Util.Split(body, ",")) do
        local d, n, h = item:match("^([0-9a-z]+):(%d+):([0-9a-z]+)$")
        if d then out[Util.FromBase36(d)] = { n = tonumber(n), h = Util.FromBase36(h) } end
    end
    return true
end

-- Ids the peer holds with confirmations we lack. mineFlags: id -> flags.
function Sync.Wanted(mineFlags, theirIds)
    local out = {}
    for id, fl in pairs(theirIds) do
        local m = mineFlags[id]
        if m == nil or (fl % 2 == 1 and m % 2 == 0) or (fl >= 2 and m < 2) then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- Ids we hold with confirmations the peer lacks (to push).
function Sync.Offer(mineFlags, theirIds)
    local out = {}
    for id, m in pairs(mineFlags) do
        local fl = theirIds[id]
        if fl == nil or (m % 2 == 1 and fl % 2 == 0) or (m >= 2 and fl < 2) then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- Days whose bucket differs from ours (either side may hold more).
function Sync.DiffDays(mine, theirs)
    local out = {}
    for d, b in pairs(theirs) do
        local m = mine.days[d]
        if not m or m.n ~= b.n or m.h ~= b.h then out[#out + 1] = d end
    end
    table.sort(out, function(x, y) return x > y end)  -- newest first
    return out
end

-- Days we hold that the peer does not have at all (for pushing).
function Sync.DaysTheyLack(mine, theirs)
    local out = {}
    for d in pairs(mine.days) do
        if not theirs[d] then out[#out + 1] = d end
    end
    table.sort(out, function(x, y) return x > y end)
    return out
end

-- ids are id..flagDigit (0-3: bit 1 = a confirmed, bit 2 = b confirmed).
function Sync.EncodeIds(day, ids)
    local sorted = {}
    for i, id in ipairs(ids) do sorted[i] = id end
    table.sort(sorted)
    local lines = Sync.Chunk("SLI~" .. Util.Base36(day) .. "~", sorted)
    lines[#lines + 1] = "SLE~" .. Util.Base36(day)
    return lines
end

function Sync.DecodeIds(text)
    local d, body = text:match("^SLI~([0-9a-z]+)~(.*)$")
    if not d then return nil end
    local ids = {}
    for _, item in ipairs(Util.Split(body, ",")) do
        local id, fl = item:match("^([0-9a-z]+)([0-3])$")
        if id and #id == 12 then ids[id] = tonumber(fl) end
    end
    return Util.FromBase36(d), ids
end

function Sync.EncodeGets(ids)
    local lines, batch = {}, {}
    for _, id in ipairs(ids) do
        batch[#batch + 1] = id
        if #batch >= Sync.MAX_IDS_PER_GET then
            lines[#lines + 1] = "SG~" .. table.concat(batch, ",")
            batch = {}
        end
    end
    if #batch > 0 then lines[#lines + 1] = "SG~" .. table.concat(batch, ",") end
    return lines
end

function Sync.DecodeGets(text)
    local body = text:match("^SG~(.*)$")
    if not body then return nil end
    local ids = {}
    for _, id in ipairs(Util.Split(body, ",")) do
        if id:match("^[0-9a-z]+$") and #id == 12 then ids[#ids + 1] = id end
        if #ids >= Sync.MAX_IDS_PER_GET then break end
    end
    return ids
end

return Sync
