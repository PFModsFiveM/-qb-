-- Minimal test framework: describe / it / assertions, plus a JSON summary for the harness.
local results = { passed = 0, failed = 0, failures = {} }
local stack = {}

function describe(name, fn)
    stack[#stack + 1] = name
    fn()
    stack[#stack] = nil
end

function it(name, fn)
    if BeforeEach then BeforeEach() end
    local ok, err = pcall(fn)
    if ok then
        results.passed = results.passed + 1
    else
        results.failed = results.failed + 1
        local path = table.concat(stack, ' > ')
        results.failures[#results.failures + 1] = (path ~= '' and path .. ' > ' or '') .. name .. ': ' .. tostring(err)
    end
end

local function fmt(v)
    if type(v) == 'string' then return string.format('%q', v) end
    return tostring(v)
end

function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg and msg .. ': ' or '') .. 'expected ' .. fmt(expected) .. ', got ' .. fmt(actual), 2)
    end
end

function assert_true(v, msg)
    if not v then error((msg or 'expected truthy') .. ' (got ' .. fmt(v) .. ')', 2) end
end

function assert_false(v, msg)
    if v then error((msg or 'expected falsy') .. ' (got ' .. fmt(v) .. ')', 2) end
end

function assert_near(actual, expected, tolerance, msg)
    if type(actual) ~= 'number' or math.abs(actual - expected) > (tolerance or 1e-6) then
        error((msg and msg .. ': ' or '') .. 'expected ~' .. fmt(expected) .. ', got ' .. fmt(actual), 2)
    end
end

function load_resource(rel)
    local src = __readfile(rel)
    local fn, err = load(src, '@' .. rel)
    if not fn then error(err, 2) end
    return fn()
end

local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
        return string.format('\\u%04x', c:byte())
    end) .. '"'
end

function __SUMMARY_JSON()
    local parts = {}
    for i, f in ipairs(results.failures) do parts[i] = jsonString(f) end
    return '{"passed":' .. results.passed .. ',"failed":' .. results.failed .. ',"failures":[' .. table.concat(parts, ',') .. ']}'
end
