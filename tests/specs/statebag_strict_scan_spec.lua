-- sv_stateBagStrictMode: with it on, a client can no longer write replicated state bags. This scan
-- reads every client and shared script of both repositories (from each resource's fxmanifest) and
-- fails on any client write of a state bag that is not a local one: `bag:set(key, value, false)`.
-- It also fails when a client writes, even locally, a key the server owns (a local value would
-- hide the server's on that client), and when a local key is not in LOCAL_KEYS (each one is
-- documented with who reads it, so a key other players or the server need cannot slip in as
-- "local").
--
-- Replicated values a client used to write are now set by the server after checks:
--   inv_busy      pfm-inventory  (open inventories, login, 'qb-inventory:server:setActionBusy')
--   qb-fuel       pfm-fuel       ('qb-fuel:server:syncFuel')
--   nos           pf-mechanicjob ('pf_mech:nos:*' events, admin customs)
--   pfDriftTires  pf-mechanicjob (performance upgrade handler, admin customs)
--   partDamage    pf-mechanicjob (repairs, alignment, admin customs, 'pf_mech:server:setState')
--   mileage       pf-mechanicjob (admin customs, 'pf_mech:server:setState')

-- ── keys ──────────────────────────────────────────────────────────
-- Written by the server only. A client must ask the server instead of writing these.
local SERVER_OWNED = {
    inv_busy = true, ['qb-fuel'] = true, nos = true, pfDriftTires = true,
    partDamage = true, mileage = true, pf_jobId = true,
}

-- Keys a client may keep as LOCAL state (`:set(key, value, false)`), with the reason it is enough.
local LOCAL_KEYS = {
    isLoggedIn = 'pfm-core client: only client scripts read it (LocalPlayer.state.isLoggedIn); no server code reads Player(src).state.isLoggedIn',
    pfWaterReshaped = 'pf-watercontrol client: read only by the same client (survives a resource restart)',
    hasNozzle = 'pfm-fuel client: read only by its own target options',
    nozzleAttached = 'pfm-fuel client: only the nozzle holder acts on it; another player\'s "remove nozzle" had no nozzle of its own to remove',
}

-- Writes proven local that the rules above would flag. Format: [file] = { [key] = 'proof' }.
local ALLOWLIST = {}

-- Writes in files outside this change (other work in progress). They still break under strict
-- mode until fixed: clear the entry when the file is fixed. Format: [file] = { [key] = 'fix' }.
local PENDING = {
}

-- ── source helpers ────────────────────────────────────────────────
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- Two copies of `src` with the same length and line breaks: `code` has comments blanked (strings
-- kept, to read keys), `bare` also has string contents blanked (where calls are looked for, so
-- commented-out code and text inside strings are never taken for a write).
local function maskSource(src)
    local code, bare, i, n = {}, {}, 1, #src
    local function both(s) code[#code + 1] = s; bare[#bare + 1] = s end
    while i <= n do
        local j = src:find('[%-\'"%[]', i)
        if not j then both(src:sub(i)) break end
        both(src:sub(i, j - 1))
        local c = src:sub(j, j)
        if c == '-' and src:sub(j + 1, j + 1) == '-' then
            local eq = src:match('^%[(=*)%[', j + 2)
            local stop
            if eq then
                local e = src:find(']' .. eq .. ']', j + 2, true)
                stop = e and (e + #eq + 1) or n
            else
                local e = src:find('\n', j, true)
                stop = e and (e - 1) or n
            end
            both((src:sub(j, stop):gsub('[^\n]', ' ')))
            i = stop + 1
        elseif c == '"' or c == "'" then
            local k = j + 1
            while k <= n do
                local d = src:sub(k, k)
                if d == '\\' then k = k + 2
                elseif d == c or d == '\n' then break
                else k = k + 1 end
            end
            k = math.min(k, n)
            code[#code + 1] = src:sub(j, k)
            bare[#bare + 1] = c .. (src:sub(j + 1, k - 1):gsub('[^\n]', 'x')) .. src:sub(k, k)
            i = k + 1
        elseif c == '[' and src:match('^%[=*%[', j) then
            local eq = src:match('^%[(=*)%[', j)
            local e = src:find(']' .. eq .. ']', j, true)
            local stop = e and (e + #eq + 1) or n
            code[#code + 1] = src:sub(j, stop)
            bare[#bare + 1] = (src:sub(j, stop):gsub('[^\n]', 'x'))
            i = stop + 1
        else
            both(c)
            i = j + 1
        end
    end
    return table.concat(code), table.concat(bare)
end

-- The arguments of the call whose `(` is just before position i, split at top-level commas.
local function splitArgs(code, i)
    local args, depth, start, j, n = {}, 0, i, i, #code
    while j <= n do
        local c = code:sub(j, j)
        if c == '"' or c == "'" then
            j = j + 1
            while j <= n do
                local d = code:sub(j, j)
                if d == '\\' then j = j + 2 elseif d == c then break else j = j + 1 end
            end
        elseif c == '[' and code:match('^%[=*%[', j) then
            local eq = code:match('^%[(=*)%[', j)
            local e = code:find(']' .. eq .. ']', j, true)
            j = e and (e + #eq + 1) or n
        elseif c == '(' or c == '{' or c == '[' then
            depth = depth + 1
        elseif c == ')' or c == '}' or c == ']' then
            if depth == 0 then
                args[#args + 1] = trim(code:sub(start, j - 1))
                return args
            end
            depth = depth - 1
        elseif c == ',' and depth == 0 then
            args[#args + 1] = trim(code:sub(start, j - 1))
            start = j + 1
        end
        j = j + 1
    end
    return args
end

local function keyOf(expr)
    local lit = expr and (expr:match('^"(.*)"$') or expr:match("^'(.*)'$"))
    if lit then return lit end
    return '[' .. tostring(expr) .. ']'
end

local function lineAt(code, pos)
    local _, count = code:sub(1, pos):gsub('\n', '')
    return count + 1
end

--- Every state bag write in `src`: { line, key, replicated, kind }. `replicated` is false only
--- for a literal `false` third argument of :set.
function ScanStateWrites(src)
    local code, bare = maskSource(src)
    local writes = {}
    local function add(pos, key, replicated, kind)
        writes[#writes + 1] = { line = lineAt(bare, pos), key = key, replicated = replicated, kind = kind }
    end
    -- calls: bag:set(key, value, replicated) / SetStateBagValue(bag, key, payload, size, replicated)
    for _, call in ipairs({ { ':%s*set%s*%(', 1, 3, ':set' }, { '%f[%w_]SetStateBagValue%s*%(', 2, 5, 'SetStateBagValue' } }) do
        local pos = 1
        while true do
            local s, e = bare:find(call[1], pos)
            if not s then break end
            local args = splitArgs(code, e + 1)
            add(s, keyOf(args[call[2]]), args[call[3]] ~= 'false', call[4])
            pos = e + 1
        end
    end
    -- assignments: x.state.key = v / x.state[key] = v, and through a local alias of a bag
    -- (client-side these are local, but they are not :set(..., false), so they are flagged too)
    local pats = { '%.state%.([%a_][%w_]*)%s*[=][^=]', '%.state(%b[])%s*[=][^=]' }
    for name, rhs in bare:gmatch('local%s+([%a_][%w_]*)%s*[=]%s*([^\n;]-)%s*\n') do
        if rhs:match('%.state$') or rhs:match('%.state%s+or%s+{%s*}$') then
            pats[#pats + 1] = '%f[%w_.]' .. name .. '%.([%a_][%w_]*)%s*[=][^=]'
            pats[#pats + 1] = '%f[%w_.]' .. name .. '(%b[])%s*[=][^=]'
        end
    end
    for _, pat in ipairs(pats) do
        local pos = 1
        while true do
            local s, e = bare:find(pat, pos)
            if not s then break end
            local _, _, k = code:find('^' .. pat, s)
            k = k or '?'
            if k:sub(1, 1) == '[' then k = keyOf(trim(k:sub(2, -2))) end
            add(s, k, true, 'assign')
            pos = e
        end
    end
    table.sort(writes, function(a, b) return a.line < b.line end)
    return writes
end

--- Why a write breaks the rules, or nil when it is fine.
function WriteProblem(w)
    if SERVER_OWNED[w.key] then return 'server-owned key written by a client' end
    if w.replicated then return 'replicated write (not :set(key, value, false))' end
    if not LOCAL_KEYS[w.key] then return 'local key not documented in LOCAL_KEYS' end
    return nil
end

-- ── manifests ─────────────────────────────────────────────────────
local function readManifest(rel)
    local ok, src = pcall(__readfile, rel)
    if not ok then return nil end
    local lists = { client = {}, shared = {} }
    local env = setmetatable({}, { __index = function(_, name)
        local kind = (name == 'client_script' or name == 'client_scripts') and 'client'
            or (name == 'shared_script' or name == 'shared_scripts') and 'shared' or nil
        local function rec(arg)
            if kind and type(arg) == 'string' then
                lists[kind][#lists[kind] + 1] = arg
            elseif kind and type(arg) == 'table' then
                for _, v in ipairs(arg) do
                    if type(v) == 'string' then lists[kind][#lists[kind] + 1] = v end
                end
            end
            return rec
        end
        return rec
    end })
    local fn = load(src, '@' .. rel, 't', env)
    if not fn or not pcall(fn) then return nil end
    return lists
end

local function globPattern(glob)
    local p = glob:gsub('^%./', ''):gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')
    p = p:gsub('%*%*/?', '\1'):gsub('%*', '[^/]*'):gsub('\1', '.*')
    return '^' .. p .. '$'
end

local function loadLister()
    local errs = {}
    for _, p in ipairs({ 'js/statebag_scan_fs.js', 'tests/js/statebag_scan_fs.js' }) do
        local fn, err = package.loadlib(p, 'list')
        if fn then return fn end
        errs[#errs + 1] = tostring(err)
    end
    error('cannot load tests/js/statebag_scan_fs.js: ' .. table.concat(errs, ' | '))
end

-- Every client or shared script of both repositories: { [path] = resource dir }.
local function clientScripts()
    local list = loadLister()
    local files = {}
    for _, root in ipairs({ 'qb', '[pfscripts]' }) do
        for _, f in ipairs(list(root)) do files[#files + 1] = f end
    end
    local resources = {}
    for _, f in ipairs(files) do
        local dir = f:match('^(.*)/fxmanifest%.lua$') or f:match('^(.*)/__resource%.lua$')
        if dir then resources[#resources + 1] = { dir = dir, manifest = f } end
    end
    -- deepest resource first, so a file belongs to the nearest manifest
    table.sort(resources, function(a, b) return #a.dir > #b.dir end)
    local out, manifests = {}, 0
    local byRes = {}
    for _, res in ipairs(resources) do
        local lists = readManifest(res.manifest)
        if lists then
            manifests = manifests + 1
            local pats = {}
            for _, kind in ipairs({ 'client', 'shared' }) do
                for _, g in ipairs(lists[kind]) do
                    if g:sub(1, 1) ~= '@' then pats[#pats + 1] = globPattern(g) end
                end
            end
            byRes[#byRes + 1] = { dir = res.dir, pats = pats }
        end
    end
    for _, f in ipairs(files) do
        for _, res in ipairs(byRes) do
            local prefix = res.dir .. '/'
            if f:sub(1, #prefix) == prefix then
                local rel = f:sub(#prefix + 1)
                for _, pat in ipairs(res.pats) do
                    if rel:match(pat) then out[f] = res.dir break end
                end
                break
            end
        end
    end
    return out, manifests, #files
end

-- ── specs ─────────────────────────────────────────────────────────
describe('state bag scanner', function()
    it('finds replicated writes in every form, and only those', function()
        local sample = table.concat({
            "LocalPlayer.state:set('inv_busy', true, true)",            -- 1
            "LocalPlayer.state:set('isLoggedIn', true, false)",        -- 2 local
            "Entity(veh).state:set('nos', {",                          -- 3 multi-line
            "    has = true, level = f(1, 2),",
            "}, true)",
            "-- Entity(veh).state:set('commented', 1, true)",          -- 6 comment
            "local st = Entity(veh).state",                            -- 7
            "st:set('partDamage', pd, true)",                          -- 8 alias :set
            "st.mileage = 5",                                          -- 9 alias assign
            "if st.mileage == 5 then end",                             -- 10 comparison only
            "Entity(v).state['qb-fuel'] = 1.0",                        -- 11 index assign
            "local s = 'x:set(1, 2, true)'",                           -- 12 inside a string
            "SetStateBagValue(bag, 'k', p, #p, true)",                 -- 13 native
            "--[[ LocalPlayer.state:set('block', 1, true) ]]",         -- 14 block comment
            "st:set(key, value, true)",                                -- 15 dynamic key
        }, '\n') .. '\n'
        local w = ScanStateWrites(sample)
        local lines = {}
        for _, x in ipairs(w) do lines[#lines + 1] = x.line .. ':' .. x.key .. ':' .. tostring(x.replicated) end
        assert_eq(table.concat(lines, ' '),
            "1:inv_busy:true 2:isLoggedIn:false 3:nos:true 8:partDamage:true 9:mileage:true 11:qb-fuel:true 13:k:true 15:[key]:true")
    end)
    it('local writes pass only for documented keys, never for server-owned ones', function()
        assert_eq(WriteProblem({ key = 'isLoggedIn', replicated = false }), nil)
        assert_true(WriteProblem({ key = 'isLoggedIn', replicated = true }) ~= nil)
        assert_true(WriteProblem({ key = 'inv_busy', replicated = false }) ~= nil, 'local inv_busy hides the server value')
        assert_true(WriteProblem({ key = 'somethingNew', replicated = false }) ~= nil, 'undocumented local key')
    end)
end)

describe('repository scan (sv_stateBagStrictMode)', function()
    local scripts, manifests, fileCount = clientScripts()

    it('reads every resource manifest and finds the client scripts', function()
        local n = 0
        for _ in pairs(scripts) do n = n + 1 end
        assert_true(manifests >= 70, 'manifests read: ' .. manifests)
        assert_true(fileCount >= 1000, 'lua files listed: ' .. fileCount)
        assert_true(n >= 200, 'client/shared scripts: ' .. n)
        for _, f in ipairs({
            'pfm-fuel/client/main.lua', 'pfm-inventory/client/main.lua', 'pfm-core/client/events.lua',
            'pfm-smallresources/client/seatbelt.lua', '[pfscripts]/pf-mechanicjob/client/nos.lua',
            '[pfscripts]/pf-watercontrol/client.lua', '[pfscripts]/pf-mechanicjob/config.lua',
        }) do
            assert_true(scripts[f] ~= nil, 'scanned: ' .. f)
        end
        assert_eq(scripts['pfm-fuel/server/main.lua'], nil, 'server scripts are not client scripts')
    end)

    it('no client script writes replicated or server-owned state', function()
        local problems, pendingSeen = {}, {}
        local paths = {}
        for f in pairs(scripts) do paths[#paths + 1] = f end
        table.sort(paths)
        for _, f in ipairs(paths) do
            local src = __readfile(f)
            if src:find(':set', 1, true) or src:find('.state', 1, true) or src:find('SetStateBagValue', 1, true) then
                for _, w in ipairs(ScanStateWrites(src)) do
                    local why = WriteProblem(w)
                    if why and ALLOWLIST[f] and ALLOWLIST[f][w.key] then why = nil end
                    if why and PENDING[f] and PENDING[f][w.key] then
                        pendingSeen[f .. ' ' .. w.key] = true
                        why = nil
                    end
                    if why then problems[#problems + 1] = ('%s:%d %s (%s)'):format(f, w.line, w.key, why) end
                end
            end
        end
        -- a pending entry whose write is gone should be removed from PENDING
        for f, keys in pairs(PENDING) do
            for k in pairs(keys) do
                if not pendingSeen[f .. ' ' .. k] then print('[statebag scan] pending entry fixed, remove it: ' .. f .. ' ' .. k) end
            end
        end
        assert_eq(#problems, 0, 'client state writes that break sv_stateBagStrictMode:\n  ' .. table.concat(problems, '\n  '))
    end)
end)
