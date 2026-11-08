-- Minimal test framework + loader for the addon's pure modules.
local passed, failed, failures, current = 0, 0, {}, "?"

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

local function deepEq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1 else
        failed = failed + 1
        failures[#failures + 1] = current .. " :: " .. name .. "\n" .. tostring(err)
    end
end

function eq(actual, expected, msg)
    if not deepEq(actual, expected) then
        error((msg and (msg .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
    end
end

function ok(v, msg) if not v then error(msg or "expected truthy", 2) end end

local CORE = { "Init", "Elo", "Ledger", "Agreement", "DuelTracker", "SyncProto", "SyncEngine", "DB" }

-- Fresh namespace with every pure module loaded, like the .toc does.
function load_ns()
    local ns = {}
    for _, name in ipairs(CORE) do
        local path = ROOT .. "/Duel/Core/" .. name .. ".lua"
        local chunk = assert(loadfile(path))
        chunk("Duel", ns)
    end
    return ns
end

-- Fake clock + scheduler for state machines.
function new_clock()
    local c = { t = 1000, q = {} }
    function c.now() return c.t end
    function c.after(sec, fn) c.q[#c.q + 1] = { at = c.t + sec, fn = fn } end
    function c.advance(sec)
        c.t = c.t + sec
        local again = true
        while again do
            again = false
            for i, job in ipairs(c.q) do
                if job.at <= c.t then
                    table.remove(c.q, i)
                    job.fn()
                    again = true
                    break
                end
            end
        end
    end
    return c
end

function run_spec(name, src)
    current = name
    local chunk, err = loadstring(src, "@" .. name)
    if not chunk then
        failed = failed + 1
        failures[#failures + 1] = name .. " :: load\n" .. err
        return
    end
    local okRun, e = xpcall(chunk, debug.traceback)
    if not okRun then
        failed = failed + 1
        failures[#failures + 1] = name .. " :: top-level\n" .. tostring(e)
    end
end

function summary()
    local lines = {}
    for _, f in ipairs(failures) do lines[#lines + 1] = "FAIL " .. f end
    lines[#lines + 1] = string.format("%d passed, %d failed", passed, failed)
    return passed, failed, table.concat(lines, "\n\n")
end
