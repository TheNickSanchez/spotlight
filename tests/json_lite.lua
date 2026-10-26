-- A small JSON encoder/decoder standing in for KOReader's rapidjson in the
-- desktop tests (encode, decode, array; options: pretty, sort_keys).
local json = {}

local ARRAY = { __jsontype = "array" }

function json.array(t)
    return setmetatable(t or {}, ARRAY)
end

local function isArray(t)
    if getmetatable(t) == ARRAY then return true end
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n > 0 and n == #t
end

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode(v, indent, depth)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return escapes[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if t == "table" then
        local nl = indent and ("\n" .. string.rep("  ", depth + 1)) or ""
        local close = indent and ("\n" .. string.rep("  ", depth)) or ""
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = encode(v[i], indent, depth + 1) end
            if #parts == 0 then return "[]" end
            return "[" .. nl .. table.concat(parts, "," .. nl) .. close .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _i, k in ipairs(keys) do
            parts[#parts + 1] = encode(k) .. ":" .. (indent and " " or "") .. encode(v[k], indent, depth + 1)
        end
        if #parts == 0 then return "{}" end
        return "{" .. nl .. table.concat(parts, "," .. nl) .. close .. "}"
    end
    error("cannot encode " .. t)
end

function json.encode(v, opts)
    return encode(v, opts and opts.pretty, 0)
end

function json.decode(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local value
    local function str()
        local out = {}
        i = i + 1
        while true do
            local c = s:sub(i, i)
            if c == "" then error("unterminated string") end
            if c == '"' then i = i + 1 break end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                if e == "u" then
                    out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256)
                    i = i + 6
                else
                    out[#out + 1] = ({ n = "\n", r = "\r", t = "\t" })[e] or e
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}
            i = i + 1
            ws()
            if s:sub(i, i) == "}" then i = i + 1 return t end
            while true do
                ws()
                local k = str()
                ws()
                assert(s:sub(i, i) == ":", "expected :")
                i = i + 1
                t[k] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "}" then return t end
                assert(d == ",", "expected , or }")
            end
        elseif c == "[" then
            local t = json.array({})
            i = i + 1
            ws()
            if s:sub(i, i) == "]" then i = i + 1 return t end
            while true do
                t[#t + 1] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "]" then return t end
                assert(d == ",", "expected , or ]")
            end
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            assert(num and #num > 0, "unexpected character at " .. i)
            i = i + #num
            return tonumber(num)
        end
    end
    local v = value()
    ws()
    assert(i > #s, "trailing characters")
    return v
end

return json
