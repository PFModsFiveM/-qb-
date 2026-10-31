-- pf-government announcements (mocked): every create path (the government UI's gov:createAnnouncement,
-- announcement:create, the CreateAnnouncementAs export) needs Config.GovApps.AnnouncementPermission,
-- the author is always the poster's character name, title/body/priority/category/duration are
-- validated, and withdrawing needs the same permission. The unchecked net event
-- pf-government:server:createAnnouncement is gone.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pf-services'] = true, ['pf-government'] = true, ['pfm-core'] = true, ['pf-computer'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
vec4 = vec4 or vector4
GlobalState = {}

local DB = { handlers = {}, nextId = 100, inserts = {}, updates = {} }
local function on(fragment, fn) table.insert(DB.handlers, 1, { fragment, fn }) end
local function run(kind, q, p)
    if kind == 'insert' and q:find('pf_gov_announcements', 1, true) then DB.inserts[#DB.inserts + 1] = p end
    if kind == 'update' and q:find('pf_gov_announcements', 1, true) then DB.updates[#DB.updates + 1] = p end
    for _, h in ipairs(DB.handlers) do if q:find(h[1], 1, true) then return h[2](p or {}, kind) end end
    if kind == 'insert' then DB.nextId = DB.nextId + 1 return DB.nextId end
    if kind == 'update' then return 1 end
    if kind == 'query' then return {} end
    return nil
end
local function op(kind)
    local function call(q, p, cb)
        if type(p) == 'function' then cb, p = p, nil end
        local out = run(kind, q, p)
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return call(q, p) end }, { __call = function(_, q, p, cb) return call(q, p, cb) end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), scalar = op('scalar'), single = op('single'), prepare = op('query') }

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/taxes.lua', 'server/budgets.lua', 'server/laws.lua', 'server/licenses.lua',
    'server/utilities.lua', 'server/bills.lua', 'server/businesses.lua', 'server/staff.lua', 'server/callbacks.lua',
    'server/loans.lua', 'server/infrastructure.lua', 'server/integrations.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
local audits = {}
function LogAudit(action, cid, name, ttype, tid) audits[#audits + 1] = { action = action, cid = cid, name = name, id = tid } end
function NotifyGovernment() end
function DebugPrint() end
function IsGovernmentEmployee(src) local P = Mock.players[src] return P ~= nil and P.PlayerData.job.name == 'government' end
GovSchema.Ensure = function() return true end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']

local events = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) events[#events + 1] = { kind = kind, data = data, opts = opts or {} } return #events end,
}
local function emitted(kind)
    local out = {}
    for _, e in ipairs(events) do if e.kind == kind then out[#out + 1] = e end end
    return out
end
local function nui(src, action, data)
    local got
    data = data or {}
    data.source = src
    Government.NuiCallbacks[action](data, function(r) got = r end)
    return got
end
-- the way a client reaches these handlers: the router, which overrides any `source` the client sends
local function viaRouter(src, action, data)
    Mock.clientEvents = {}
    Mock.fireNet('pf-government:server:nuiCallback', src, 7, action, data)
    for _, e in ipairs(Mock.clientEvents) do
        if e.name == 'pf-government:client:nuiCallback' and e.target == src then return e.args[2] end
    end
end
local function broadcasts()
    local n = 0
    for _, e in ipairs(Mock.clientEvents) do if e.name == 'QBCore:Notify' and e.target == -1 then n = n + 1 end end
    return n
end
local function syncs(action)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'pf-computer:gov:announcements:sync' and e.args[1].action == action then n = n + 1 end
    end
    return n
end

local MAYOR, DEPUTY, TREASURER, CLERK, CIV = 1, 2, 3, 4, 5
local function gov(src, cid, grade, first, last)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'government', grade = { level = grade }, onduty = true }
    p.PlayerData.charinfo = { firstname = first, lastname = last }
    return p
end

BeforeEach = function()
    events = {}
    audits = {}
    Mock.reset()
    DB.handlers, DB.inserts, DB.updates = {}, {}, {}
    Mock.players = {}
    gov(MAYOR, 'MAY1', 4, 'Maya', 'Mayor')
    gov(DEPUTY, 'DEP1', 3, 'Dan', 'Deputy')        -- has 'laws'
    gov(TREASURER, 'TRE1', 2, 'Tess', 'Treasurer') -- no 'laws'
    gov(CLERK, 'CLK1', 1, 'Carl', 'Clerk')         -- no 'laws'
    Mock.newPlayer(CIV, 'CIV1')
    Config.GovApps.AnnouncementPermission = 'laws'
    Config.GovApps.UrgentAnnouncementPermission = nil
end

describe('gov:createAnnouncement (the government UI form)', function()
    it('a government employee without the announcement permission cannot post', function()
        for _, src in ipairs({ TREASURER, CLERK, CIV }) do
            local res = viaRouter(src, 'gov:createAnnouncement', { title = 'Free money', body = 'Everyone gets a million.', author = 'Mayor' })
            assert_false(res.ok, 'src ' .. src)
            assert_eq(res.error, 'no_permission')
        end
        assert_eq(#DB.inserts, 0, 'nothing stored')
        assert_eq(#emitted('gov.announcement'), 0, 'nothing on the city timeline')
        assert_eq(syncs('create'), 0)
    end)
    it('a client cannot post as someone else by sending source', function()
        local res = viaRouter(CLERK, 'gov:createAnnouncement', { source = MAYOR, title = 'Hi', body = 'Hello' })
        assert_false(res.ok)
        assert_eq(#DB.inserts, 0)
    end)
    it('the author always comes from the server, never from the client', function()
        local res = viaRouter(DEPUTY, 'gov:createAnnouncement', { title = 'Road works', body = 'Vinewood is closed.', author = 'The Mayor' })
        assert_true(res.ok)
        assert_eq(#DB.inserts, 1)
        assert_eq(DB.inserts[1][1], 'Road works')
        assert_eq(DB.inserts[1][2], 'Vinewood is closed.')
        assert_eq(DB.inserts[1][3], 'normal')
        assert_eq(DB.inserts[1][5], 'DEP1')
        assert_eq(DB.inserts[1][6], 'Dan Deputy', 'created_by_name is the character name')
        local ev = emitted('gov.announcement')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.author, 'Dan Deputy')
        assert_eq(ev[1].data.priority, 'normal')
        assert_eq(broadcasts(), 0, 'a normal announcement raises no alert')
        assert_eq(syncs('create'), 1)
    end)
    it('rejects missing, non-string and oversized fields', function()
        local bad = {
            { title = nil, body = 'x' },
            { title = 'x', body = nil },
            { title = { 'x' }, body = 'x' },
            { title = 'x', body = 42 },
            { title = '   ', body = 'x' },
            { title = string.rep('a', 121), body = 'x' },
            { title = 'x', body = string.rep('b', 4001) },
            { title = 'x', body = 'x', duration = 'forever' },
            { title = 'x', body = 'x', duration = -5 },
        }
        for i, d in ipairs(bad) do
            local res = viaRouter(DEPUTY, 'gov:createAnnouncement', d)
            assert_false(res.ok, 'case ' .. i)
            assert_eq(res.error, 'invalid', 'case ' .. i)
        end
        assert_eq(#DB.inserts, 0)
    end)
end)

describe('announcement:create', function()
    it('validates priority and category', function()
        assert_eq(nui(DEPUTY, 'announcement:create', { title = 'x', content = 'y', priority = 'apocalypse' }).error, 'invalid')
        assert_eq(nui(DEPUTY, 'announcement:create', { title = 'x', content = 'y', priority = { 'urgent' } }).error, 'invalid')
        assert_eq(nui(DEPUTY, 'announcement:create', { title = 'x', content = 'y', category = '<script>' }).error, 'invalid')
        assert_eq(nui(DEPUTY, 'announcement:create', { title = 'x', content = 'y', category = string.rep('c', 33) }).error, 'invalid')
        assert_eq(#DB.inserts, 0)
        assert_true(nui(DEPUTY, 'announcement:create', { title = 'x', content = 'y', category = 'road works' }).ok)
        assert_eq(DB.inserts[1][4], 'road works')
    end)
    it('urgent needs the urgent permission (by default the announcement permission)', function()
        assert_false(viaRouter(CLERK, 'announcement:create', { title = 'Evacuate', content = 'Now', priority = 'urgent' }).ok)
        assert_eq(broadcasts(), 0)
        Config.GovApps.UrgentAnnouncementPermission = 'all'
        local res = nui(DEPUTY, 'announcement:create', { title = 'Evacuate', content = 'Now', priority = 'urgent' })
        assert_false(res.ok, 'deputy has laws, not the urgent permission')
        assert_eq(res.error, 'no_permission')
        assert_eq(#DB.inserts, 0)
        assert_true(nui(DEPUTY, 'announcement:create', { title = 'Notice', content = 'Calm', priority = 'high' }).ok, 'high is fine')
        Mock.clientEvents = {}
        assert_true(nui(MAYOR, 'announcement:create', { title = 'Evacuate', content = 'Now', priority = 'urgent' }).ok)
        assert_eq(broadcasts(), 1, 'urgent alert from the mayor')
        local ev = emitted('gov.announcement')
        assert_eq(ev[#ev].data.priority, 'urgent')
        assert_eq(ev[#ev].data.author, 'Maya Mayor')
    end)
    it('caps the duration', function()
        assert_true(nui(DEPUTY, 'announcement:create', { title = 'x', content = 'y', duration = 1e12 }).ok)
        assert_true(DB.inserts[1][7] ~= nil, 'expires')
    end)
end)

describe('CreateAnnouncementAs (pf-computer)', function()
    it('goes through the same permission check', function()
        local res = exports['pf-government']:CreateAnnouncementAs(CLERK, { title = 'Hi', content = 'There', priority = 'urgent' })
        assert_false(res.ok)
        assert_eq(res.error, 'no_permission')
        assert_eq(#DB.inserts, 0)
        res = exports['pf-government']:CreateAnnouncementAs(DEPUTY, { title = 'Hi', content = 'There', author = 'Someone Else' })
        assert_true(res.ok)
        assert_eq(DB.inserts[1][6], 'Dan Deputy')
    end)
end)

describe('announcement:delete', function()
    it('needs the announcement permission', function()
        for _, src in ipairs({ TREASURER, CLERK, CIV }) do
            local res = viaRouter(src, 'announcement:delete', { announcementId = 5 })
            assert_false(res.ok, 'src ' .. src)
            assert_eq(res.error, 'no_permission')
        end
        assert_eq(#DB.updates, 0, 'nothing withdrawn')
        assert_eq(syncs('delete'), 0)
    end)
    it('withdraws with the permission, rejects bad ids and missing announcements', function()
        assert_eq(viaRouter(DEPUTY, 'announcement:delete', { announcementId = 'abc' }).error, 'invalid')
        assert_eq(viaRouter(DEPUTY, 'announcement:delete', { announcementId = 1.5 }).error, 'invalid')
        assert_eq(#DB.updates, 0)
        on('UPDATE pf_gov_announcements SET active = 0', function(p) return p[1] == 5 and 1 or 0 end)
        assert_eq(viaRouter(DEPUTY, 'announcement:delete', { announcementId = 6 }).error, 'not_found')
        assert_eq(syncs('delete'), 0)
        assert_true(viaRouter(DEPUTY, 'announcement:delete', { announcementId = 5 }).ok)
        assert_eq(syncs('delete'), 1)
    end)
end)

describe('the unchecked net event', function()
    it('pf-government:server:createAnnouncement is no longer registered', function()
        assert_eq(Mock.netHandlers['pf-government:server:createAnnouncement'], nil)
    end)
end)
