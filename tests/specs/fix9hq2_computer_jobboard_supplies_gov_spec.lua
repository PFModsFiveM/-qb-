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
local collected, mayManage = {}, {}
Mock.exportsByResource['pf-stores'] = {
    RegisterBuyerKind = function() return true end,
    ListOwnedStores = function() return { ok = true, data = { stores = {} } } end,
    CollectOrder = function(_, src, kind, buyerId, orderId)
        if not mayManage[src] then return { ok = false, error = 'not_owner' } end
        collected[#collected + 1] = { src = src, orderId = orderId } return { ok = true }
    end,
    GetOrder = function(_, id) return { id = id, buyer_kind = 'jobbiz', store_id = 'mechanic', status = 'ready', method = 'pickup', items_json = '[]' } end,
    CanManageOrderBuyer = function(_, src, orderId) return mayManage[src] == true end,
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
    announcements, collected, mayManage, emitted = {}, {}, {}, {}
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
    local function pickup(src, orderId)
        local spawned = {}
        started['pf-mechanicjob'] = true
        Mock.exportsByResource['pf-mechanicjob'] = { StartSuppliesPickup = function(_, s, order) spawned[#spawned + 1] = { src = s, order = order } return true end }
        local res = call(src, 'business:supplies:orders:pickup', { orderId = orderId, mode = 'job' })
        started['pf-mechanicjob'] = nil
        Mock.exportsByResource['pf-mechanicjob'] = nil
        return res, spawned
    end

    it('a mechanic who may not collect the order gets no truck and trailer', function()
        mayManage[SENIOR] = false
        local res, spawned = pickup(SENIOR, 42)
        assert_eq(res and res.error, 'not_owner')
        assert_eq(#spawned, 0, 'no pickup run spawned')
        assert_eq(PFComputer.dataStore and PFComputer.dataStore.pickupRuns and PFComputer.dataStore.pickupRuns['SEN1'], nil)
        assert_eq(#collected, 0)
    end)
    it('a player who may collect starts the run and the finished run collects it', function()
        mayManage[BOSS] = true
        local res, spawned = pickup(BOSS, 43)
        assert_true(res and res.ok, 'run started: ' .. tostring(res and res.error))
        assert_eq(#spawned, 1)
        assert_eq(spawned[1].order.id, 43)
        TriggerEvent('pf-computer:server:supplies:completeOrder', BOSS, 43)
        assert_eq(#collected, 1)
        assert_eq(collected[1].orderId, 43)
    end)
    it('when pf-stores cannot answer the permission, nothing is spawned', function()
        local stores = Mock.exportsByResource['pf-stores']
        local real = stores.CanManageOrderBuyer
        stores.CanManageOrderBuyer = function() error('boom') end
        local res, spawned = pickup(BOSS, 44)
        stores.CanManageOrderBuyer = real
        assert_eq(res and res.error, 'stores_unavailable')
        assert_eq(#spawned, 0)
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
    it('the category is cleaned to what pf-government accepts ([A-Za-z0-9 _-], at most 32)', function()
        govPerms[STAFF] = { laws = true }
        local cases = {
            { 'Roads & Traffic', 'Roads and Traffic' },
            { 'Public-Safety', 'Public-Safety' },
            { 'health/EMS!', 'health EMS' },
            { '  !!!  ', nil },
            { '', nil },
            { string.rep('abcdefghij', 5), string.rep('abcdefghij', 3) .. 'ab' },
        }
        for i, c in ipairs(cases) do
            assert_true(call(STAFF, 'gov:announcements:create', { title = 'T' .. i, body = 'b', category = c[1] }).ok)
            local sent = announcements[i].data.category
            assert_eq(sent, c[2], 'category ' .. tostring(c[1]))
            if sent ~= nil then
                assert_true(#sent <= 32 and sent:match('^[%w _%-]+$') ~= nil, 'passes the government whitelist: ' .. sent)
            end
        end
    end)
end)
