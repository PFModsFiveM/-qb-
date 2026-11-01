-- pf-computer (fix9hq2, group computer): the Job Board hiring kind survives a pf-services restart,
-- a supplies pickup run is refused before anything spawns when the player may not collect the order,
-- and City Hall announcements reach pf-government with seconds and a category it accepts.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pfm-core'] = true, ['pfm-banking'] = false, ['pf-citizen'] = true, ['pf-government'] = true, ['pfm-inventory'] = true, ['pf-stores'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-computer' end
function LoadResourceFile() return nil end
function SaveResourceFile() return true end
function RegisterCommand() end

QBCoreMock.Shared.Jobs = {
    mechanic = { label = 'LS Customs', grades = { ['0'] = { name = 'Recruit', payment = 50 }, ['1'] = { name = 'Mechanic', payment = 75 },
        ['2'] = { name = 'Senior', payment = 100 }, ['3'] = { name = 'Lead', payment = 120 }, ['4'] = { name = 'Owner', isboss = true, payment = 150 } } },
    unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },
}

Mock.exportsByResource['pf-citizen'] = {
    SendMail = function() return true end,
    SendMailToAll = function() return true end,
}
local govPerms, announcements = {}, {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return govPerms[src] ~= nil and govPerms[src][perm] == true end,
    CreateAnnouncementAs = function(_, src, data) announcements[#announcements + 1] = { src = src, data = data } return { ok = true } end,
}
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function() return true end,
    GetInventory = function() return { items = {} } end,
    GetFreshness = function() return nil end,
}
-- pf-stores as it works: CollectOrder asks the buyer kind's adapter (pf-computer's own jobAdapter for
-- 'jobbiz') whether the player may manage the buyer, before it changes anything
local collected, orderReads, adapters = {}, 0, {}
local orderStatus = 'ready'
local onGetOrder
Mock.exportsByResource['pf-stores'] = {
    RegisterBuyerKind = function(_, kind, adapter) adapters[kind] = adapter return true end,
    ListOwnedStores = function() return { ok = true, data = { stores = {} } } end,
    CollectOrder = function(_, src, kind, buyerId, orderId)
        local adapter = adapters[kind]
        if not adapter or not adapter.canManage(src, buyerId) then return { ok = false, error = 'not_owner' } end
        collected[#collected + 1] = { src = src, orderId = orderId } return { ok = true }
    end,
    GetOrder = function(_, id)
        orderReads = orderReads + 1
        if onGetOrder then onGetOrder(id) end
        return { id = id, buyer_kind = 'jobbiz', store_id = 'mechanic', status = orderStatus, method = 'pickup', items_json = '[]' }
    end,
}

-- pf-services keeps its event kinds in memory: a restart forgets them
local kinds, emitted = {}, {}
Mock.exportsByResource['pf-services'] = {
    RegisterEventKind = function(_, kind, def) kinds[kind] = def return true end,
    GetEventKind = function(_, kind) return kinds[kind] end,
    Emit = function(_, kind, data, opts)
        if not kinds[kind] then return nil, 'unknown kind' end
        emitted[#emitted + 1] = { kind = kind, data = data, opts = opts }
        return #emitted
    end,
}

Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
load_resource('[pfscripts]/pf-computer/server/main.lua')
load_resource('[pfscripts]/pf-computer/server/jobboard.lua')
-- (the mock keeps one handler per event name: jobboard.lua's is the last onResourceStart)
local jobboardOnStart = Mock.eventHandlers['onResourceStart']

local BOSS, SENIOR, STAFF = 1, 2, 3
local function setJob(p, name, grade)
    local j = QBCoreMock.Shared.Jobs[name]
    local g = j and j.grades[tostring(grade)]
    p.PlayerData.job = { name = name, label = j.label, grade = { level = tonumber(grade), name = g.name }, isboss = g.isboss == true }
end
local function player(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.Functions.SetJob = function() return true end
    p.Functions.Save = function() end
    setJob(p, job, grade)
    return p
end
local function call(src, action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    announcements, collected, emitted = {}, {}, {}
    orderReads, orderStatus, onGetOrder = 0, 'ready', nil
    govPerms = {}
    player(BOSS, 'BOSS1', 'mechanic', 3)
    Mock.players[BOSS].PlayerData.job.isboss = true
    player(SENIOR, 'SEN1', 'mechanic', 3)
    player(STAFF, 'STAFF1', 'unemployed', 0)
    started['pf-services'] = true
end

-- a Job Board post by the boss, with the job tables "ready" (the database calls stubbed)
local nextPostId = 100
local function createPost(title)
    nextPostId = nextPostId + 1
    local realMode = PFComputer.DB.mode
    local scalar, insert = MySQL.scalar.await, MySQL.insert.await
    PFComputer.DB.mode = 'ready'
    MySQL.scalar.await = function() return 0 end
    MySQL.insert.await = function() return nextPostId end
    local ok, res = pcall(call, BOSS, 'jobs:create', { title = title })
    PFComputer.DB.mode, MySQL.scalar.await, MySQL.insert.await = realMode, scalar, insert
    assert(ok, res)
    assert(res and res.ok, 'post created: ' .. tostring(res and res.error))
    return res
end

describe('fix9hq2 computer: Job Board hiring news after a pf-services restart', function()
    it('a post after pf-services forgot the kind still reaches the city timeline (lazy registration)', function()
        kinds = {}
        createPost('Mechanic')
        assert_eq(#emitted, 1, 'first post emitted')
        assert_eq(emitted[1].kind, 'business.hiring')
        -- pf-services restarts without the start event reaching us: its kinds are gone
        kinds = {}
        createPost('Tow driver')
        assert_eq(#emitted, 2, 'the post after the restart is emitted too (was refused as unknown kind)')
        assert_true(kinds['business.hiring'] ~= nil)
        assert_eq(kinds['business.hiring'].news, 'auto')
    end)
    it('the kind is registered again when pf-services starts', function()
        kinds = {}
        assert_true(type(jobboardOnStart) == 'function', 'jobboard listens for onResourceStart')
        jobboardOnStart('pf-stores')
        assert_eq(kinds['business.hiring'], nil, 'other resources do not register it')
        jobboardOnStart('pf-services')
        assert_true(kinds['business.hiring'] ~= nil)
        assert_eq(kinds['business.hiring'].category, 'business')
    end)
    it('the kind is registered when pf-computer starts with pf-services running', function()
        kinds = {}
        jobboardOnStart('pf-computer')
        assert_true(kinds['business.hiring'] ~= nil)
    end)
    it("pf-services reading as 'starting' inside its own start event still gets the kind", function()
        kinds = {}
        local real = GetResourceState
        GetResourceState = function(name) if name == 'pf-services' then return 'starting' end return real(name) end
        jobboardOnStart('pf-services')
        GetResourceState = real
        assert_true(kinds['business.hiring'] ~= nil)
    end)
    it('a pf-services:server:ready signal registers it too', function()
        kinds = {}
        local ready = Mock.eventHandlers['pf-services:server:ready']
        assert_true(type(ready) == 'function', 'jobboard listens for pf-services:server:ready')
        ready()
        assert_true(kinds['business.hiring'] ~= nil)
    end)
    it('a pf-services that refuses or fails does not break posting', function()
        local svc = Mock.exportsByResource['pf-services']
        local realReg = svc.RegisterEventKind
        svc.RegisterEventKind = function() error('pf-services restarting') end
        kinds = {}
        createPost('Welder')
        svc.RegisterEventKind = realReg
        assert_eq(#emitted, 0, 'nothing emitted for an unknown kind')
        createPost('Welder 2')
        assert_eq(#emitted, 1, 'the next post registers and emits')
    end)
    it('nothing is registered while pf-services is not running', function()
        kinds = {}
        started['pf-services'] = nil
        jobboardOnStart('pf-services')
        createPost('Painter')
        assert_eq(#emitted, 0)
        assert_eq(kinds['business.hiring'], nil)
    end)
end)

describe('fix9hq2 computer: supplies pickup run permission', function()
    local spawned
    local function pickup(src, orderId)
        spawned = spawned or {}
        started['pf-mechanicjob'] = true
        Mock.exportsByResource['pf-mechanicjob'] = { StartSuppliesPickup = function(_, s, order) spawned[#spawned + 1] = { src = s, order = order } return true end }
        local res = call(src, 'business:supplies:orders:pickup', { orderId = orderId, mode = 'job' })
        started['pf-mechanicjob'] = nil
        Mock.exportsByResource['pf-mechanicjob'] = nil
        return res, spawned
    end
    local function runs() return PFComputer.dataStore.pickupRuns end

    it('staff who are not the boss are refused before the order is read or a truck is spawned', function()
        spawned = {}
        local res = pickup(SENIOR, 42)
        assert_eq(res and res.ok, false)
        assert_eq(res.error, 'not_boss')
        assert_eq(#spawned, 0, 'no pickup run spawned')
        assert_eq(orderReads, 0, 'refused before the order lookup')
        assert_eq(runs()['SEN1'], nil, 'no run remembered')
        assert_eq(#collected, 0)
    end)
    it('without pf-mechanicjob, staff who are not the boss cannot collect at once either', function()
        local res = call(SENIOR, 'business:supplies:orders:pickup', { orderId = 42, mode = 'job' })
        assert_eq(res and res.error, 'not_boss')
        assert_eq(#collected, 0)
    end)
    it('the boss starts the run, and the finished run collects the order', function()
        spawned = {}
        local res = pickup(BOSS, 43)
        assert_true(res and res.ok, 'run started: ' .. tostring(res and res.error))
        assert_eq(#spawned, 1)
        assert_eq(spawned[1].order.id, 43)
        assert_eq(runs()['BOSS1'].orderId, 43)
        TriggerEvent('pf-computer:server:supplies:completeOrder', BOSS, 43)
        assert_eq(#collected, 1)
        assert_eq(collected[1].orderId, 43)
        assert_eq(runs()['BOSS1'], nil)
    end)
    it('the boss check is the one pf-stores makes at collection: a boss demoted mid-run cannot collect', function()
        spawned = {}
        assert_true(pickup(BOSS, 44).ok)
        Mock.players[BOSS].PlayerData.job.isboss = false
        TriggerEvent('pf-computer:server:supplies:completeOrder', BOSS, 44)
        assert_eq(#collected, 0, 'pf-stores refused with the same rule')
    end)
    it('an order that is not ready starts nothing', function()
        spawned = {}
        orderStatus = 'awaiting_supplier'
        local res = pickup(BOSS, 45)
        assert_eq(res and res.error, 'order_not_ready')
        assert_eq(#spawned, 0)
    end)
    it('two pickup requests at once start one run', function()
        spawned = {}
        local inner
        onGetOrder = function()
            onGetOrder = nil
            -- a second request arrives while the first waits on the order read
            inner = call(BOSS, 'business:supplies:orders:pickup', { orderId = 46, mode = 'job' })
        end
        Mock.clientEvents = {}
        started['pf-mechanicjob'] = true
        Mock.exportsByResource['pf-mechanicjob'] = { StartSuppliesPickup = function(_, s, order) spawned[#spawned + 1] = { src = s, order = order } return true end }
        Mock.gameTimer = Mock.gameTimer + 100000
        local res = PFComputer.dispatch('business:supplies:orders:pickup', { orderId = 46, mode = 'job' }, BOSS)
        started['pf-mechanicjob'] = nil
        Mock.exportsByResource['pf-mechanicjob'] = nil
        assert_true(res and res.ok, 'the first started: ' .. tostring(res and res.error))
        assert_eq(inner and inner.error, 'busy', 'the second was refused')
        assert_eq(#spawned, 1, 'one truck')
        -- the lock is released afterwards
        spawned = {}
        runs()['BOSS1'] = nil
        assert_true(pickup(BOSS, 47).ok)
        assert_eq(#spawned, 1)
    end)
end)

describe('fix9hq2 computer: City Hall announcement duration and category', function()
    it('the duration in days is sent to pf-government in seconds, clamped to 1..90 days', function()
        govPerms[STAFF] = { laws = true }
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'Parade', body = 'Sunday', duration = 7 }).ok)
        assert_eq(announcements[1].data.duration, 7 * 86400)
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'Long', body = 'x', duration = 500 }).ok)
        assert_eq(announcements[2].data.duration, 90 * 86400)
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'Short', body = 'x', duration = 0 }).ok)
        assert_eq(announcements[3].data.duration, 86400)
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'None', body = 'x' }).ok)
        assert_eq(announcements[4].data.duration, nil, 'no duration: pf-government default')
    end)
    it('odd durations become whole days in range, or the default', function()
        govPerms[STAFF] = { laws = true }
        local cases = {
            { '7', 7 * 86400 }, { 2.9, 2 * 86400 }, { -3, 86400 }, { 1 / 0, 90 * 86400 }, { -1 / 0, 86400 },
            { 0 / 0, nil }, { 'soon', nil }, { true, nil },
        }
        for i, c in ipairs(cases) do
            assert_true(call(STAFF, 'gov:announcements:create', { title = 'D' .. i, body = 'b', duration = c[1] }).ok)
            assert_eq(announcements[i].data.duration, c[2], 'duration ' .. tostring(c[1]))
        end
    end)
    it('the seconds sent are what pf-government stores as the expiry (90 days at most)', function()
        govPerms[STAFF] = { laws = true }
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'Max', body = 'b', duration = 90 }).ok)
        assert_true(announcements[1].data.duration <= 90 * 86400, 'within ANNOUNCEMENT_MAX_DURATION')
        assert_true(announcements[1].data.duration >= 86400, 'at least a day, never read as 90 seconds')
    end)
    it('only officials with the announcement permission reach pf-government', function()
        govPerms[STAFF] = {}
        local res = call(STAFF, 'gov:announcements:create', { title = 'No', body = 'b', duration = 3 })
        assert_eq(res and res.error, 'not_authorized')
        assert_eq(#announcements, 0)
    end)
    it('the category is cleaned to what pf-government accepts ([A-Za-z0-9 _-], at most 32)', function()
        govPerms[STAFF] = { laws = true }
        local cases = {
            { 'Roads & Traffic', 'Roads and Traffic' },
            { 'Public-Safety', 'Public-Safety' },
            { 'health/EMS!', 'health EMS' },
            { '  !!!  ', nil },
            { '', nil },
            { string.rep('abcdefghij', 5), string.rep('abcdefghij', 3) .. 'ab' },
            { 'Taxes\n\tand fees', 'Taxes and fees' },
            { 'Café news', 'Caf news' },
            { string.rep('x', 31) .. ' y', string.rep('x', 31) },
            { string.rep('!', 5000) .. 'late', nil },
        }
        for i, c in ipairs(cases) do
            assert_true(call(STAFF, 'gov:announcements:create', { title = 'T' .. i, body = 'b', category = c[1] }).ok)
            local sent = announcements[i].data.category
            assert_eq(sent, c[2], 'category ' .. tostring(c[1]):sub(1, 40))
            if sent ~= nil then
                assert_true(#sent <= 32 and sent:match('^[%w _%-]+$') ~= nil, 'passes the government whitelist: ' .. sent)
                assert_true(sent:match('^%s') == nil and sent:match('%s$') == nil, 'trimmed: ' .. sent)
            end
        end
        -- not text at all: pf-government's default
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'N', body = 'b', category = 42 }).ok)
        assert_eq(announcements[#announcements].data.category, nil)
    end)
end)
