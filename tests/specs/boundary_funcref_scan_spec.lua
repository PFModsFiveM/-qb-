-- The QBCore object from exports['pfm-core']:GetCoreObject() is a copy: in every resource but
-- pfm-core, QBCore.Functions.X and Player.Functions.X are function references (callable tables), so
-- `type(QBCore.Functions.X) == 'function'` is always false there and the code behind such a test
-- never runs (pf-mechanicjob's QBCore progress bar, for one). This scan reads every Lua file of both
-- repositories (client, server and shared) and fails on such a test outside pfm-core; use a callable
-- check instead (a function, or a table with a string __cfx_functionReference).

local function loadLister()
    local errs = {}
    for _, p in ipairs({ 'js/statebag_scan_fs.js', 'tests/js/statebag_scan_fs.js' }) do
        local fn, err = package.loadlib(p, 'list')
        if fn then return fn end
        errs[#errs + 1] = tostring(err)
    end
    error('cannot load tests/js/statebag_scan_fs.js: ' .. table.concat(errs, ' | '))
end

-- a line without its comment (a `--` inside a string is kept)
local function code(line)
    local quote, i = nil, 1
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == '\\' then i = i + 1 elseif c == quote then quote = nil end
        elseif c == '"' or c == "'" then
            quote = c
        elseif line:sub(i, i + 1) == '--' then
            return line:sub(1, i - 1)
        end
        i = i + 1
    end
    return line
end

local PATTERN = "type%(%s*[%w_%.]*Functions%s*[%.%[][^%)]*%)%s*[~=]=%s*['\"]function['\"]"

--- { 'file:line: text' } for every type() == 'function' test on a Functions member.
function ScanFunctionsTypeTests(path, src)
    local found, n, inBlock = {}, 0, false
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        local text = line
        if inBlock then
            local e = text:find(']]', 1, true)
            if e then text = text:sub(e + 2); inBlock = false else text = '' end
        end
        local s = text:find('--[[', 1, true)
        if s and not text:sub(1, s - 1):find("['\"]") then
            local e = text:find(']]', s + 4, true)
            if e then text = text:sub(1, s - 1) .. text:sub(e + 2) else text = text:sub(1, s - 1); inBlock = true end
        end
        text = code(text)
        if text:find(PATTERN) then found[#found + 1] = ('%s:%d: %s'):format(path, n, (line:gsub('^%s+', ''))) end
    end
    return found
end

describe('type() tests on QBCore functions', function()
    it('the scanner finds the test in every form, and not in comments or callable checks', function()
        local sample = table.concat({
            "if type(QBCore.Functions.Progressbar) == 'function' then",           -- 1
            'if type( Player.Functions.SetMetaData ) ~= "function" then return end', -- 2
            "-- if type(QBCore.Functions.Notify) == 'function' then",             -- 3 comment
            "local ok = type(fn) == 'function' or rawget(fn, '__cfx_functionReference')", -- 4 other value
            "if type(QBCore.Functions['GetPlayer']) == 'function' then",          -- 5
            "--[[ type(QBCore.Functions.X) == 'function' ]]",                     -- 6 block comment
        }, '\n')
        local hits = ScanFunctionsTypeTests('sample.lua', sample)
        assert_eq(#hits, 3, table.concat(hits, ' | '))
        assert_true(hits[1]:find('sample.lua:1:', 1, true) ~= nil)
        assert_true(hits[2]:find('sample.lua:2:', 1, true) ~= nil)
        assert_true(hits[3]:find('sample.lua:5:', 1, true) ~= nil)
    end)
    it('no resource outside pfm-core tests a QBCore function with type() == \'function\'', function()
        local list = loadLister()
        local files = {}
        for _, root in ipairs({ 'qb', '[pfscripts]' }) do
            for _, f in ipairs(list(root)) do files[#files + 1] = f end
        end
        assert_true(#files > 200, 'both repositories were read (' .. #files .. ' files)')
        local problems = {}
        for _, f in ipairs(files) do
            -- pfm-core's own QBCore is the live object, its functions are functions there
            if not f:match('^pfm%-core/') then
                local ok, src = pcall(__readfile, f)
                if ok and type(src) == 'string' then
                    for _, hit in ipairs(ScanFunctionsTypeTests(f, src)) do problems[#problems + 1] = hit end
                end
            end
        end
        assert_eq(#problems, 0, 'use a callable check:\n  ' .. table.concat(problems, '\n  '))
    end)
end)
