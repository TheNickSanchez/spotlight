-- Desktop test runner for Spotlight's pure-logic modules.
-- Usage, from the project folder:  luajit tests/run.lua
-- Optionally name test files:      luajit tests/run.lua tests/test_sentences.lua

local script_dir = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = script_dir .. "/../spotlight.koplugin/?.lua;" .. script_dir .. "/?.lua;" .. package.path

local T = { passed = 0, failed = 0, current = nil }
_G.T = T

local function show(v)
    if type(v) == "table" then
        local parts = {}
        for i, x in ipairs(v) do parts[i] = show(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function T.eq(actual, expected, msg)
    if not deepEqual(actual, expected) then
        error(string.format("%s\n    expected: %s\n    actual:   %s",
            msg or "values differ", show(expected), show(actual)), 2)
    end
end

function T.ok(cond, msg)
    if not cond then error(msg or "expected true", 2) end
end

function T.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        io.write("FAIL  ", T.current, " > ", name, "\n    ", tostring(err), "\n")
    end
end

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then
    local p = io.popen('ls "' .. script_dir .. '"/test_*.lua')
    for f in p:lines() do files[#files + 1] = f end
    p:close()
end

for _, f in ipairs(files) do
    T.current = f:match("([^/]+)%.lua$")
    dofile(f)
end

io.write(string.format("\n%d passed, %d failed\n", T.passed, T.failed))
os.exit(T.failed == 0 and 0 or 1)
