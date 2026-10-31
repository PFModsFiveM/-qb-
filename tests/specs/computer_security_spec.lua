-- pf-computer: the security fixes and the removed fakes (each test is an old exploit or fake that is
-- now refused), on the mocked harness. Database behaviour: realdb_specs/computer_jobboard_realdb_spec.lua.
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

local mails, everyone, announcements = {}, {}, {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, mail) mails[#mails + 1] = { cid = cid, mail = mail } return true end,
    SendMailToAll = function(_, mail) everyone[#everyone + 1] = mail return true end,
}
local govPerms = {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return govPerms[src] ~= nil and govPerms[src][perm] == true end,
    CreateAnnouncementAs = function(_, src, data) announcements[#announcements + 1] = { src = src, data = data } return { ok = true } end,
}
local stash = {}
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function() return true end,
    GetInventory = function(_, id) return { items = stash[id] or {} } end,
    GetFreshness = function() return nil end,
}
local collected = {}
Mock.exportsByResource['pf-stores'] = {
    RegisterBuyerKind = function() return true end,
    ListOwnedStores = function() return { ok = true, data = { stores = {} } } end,
    CollectOrder = function(_, src, kind, buyerId, orderId) collected[#collected + 1] = { src = src, kind = kind, buyerId = buyerId, orderId = orderId } return { ok = true } end,
}

Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
load_resource('[pfscripts]/pf-computer/server/main.lua')
load_resource('[pfscripts]/pf-computer/server/jobboard.lua')

local BOSS, WORKER, CITIZEN, STAFF = 1, 2, 3, 4
local function setJob(p, name, grade)
    local j = QBCoreMock.Shared.Jobs[name]
    local g = j and j.grades[tostring(grade)]
    if not g then return false end
    p.PlayerData.job = { name = name, label = j.label, grade = { level = tonumber(grade), name = g.name }, isboss = g.isboss == true }
    return true
end
local function player(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.Functions.SetJob = function(name, gr) return setJob(p, name, gr) end
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
    mails, everyone, announcements, collected = {}, {}, {}, {}
    govPerms = {}
    player(BOSS, 'BOSS1', 'mechanic', 3)
    Mock.players[BOSS].PlayerData.job.isboss = true
    player(WORKER, 'WORK1', 'mechanic', 1)
    player(CITIZEN, 'CIT1', 'unemployed', 0)
    player(STAFF, 'STAFF1', 'unemployed', 0)
end

-- domains are bought through the ledger (stores_trucking_ledger_spec checks the price); here the bank says yes
local function buyDomain(src, domain)
    started['pfm-banking'] = true
    Mock.exportsByResource['pfm-banking'] = { Transfer = function() return { ok = true } end }
    local res = call(src, 'browser:domain:buy', { domain = domain })
    started['pfm-banking'] = false
    Mock.exportsByResource['pfm-banking'] = nil
    assert(res and res.ok, 'domain purchase')
end

-- a pickup run started from Order Supplies (pf-stores has the ready order, pf-mechanicjob the mission)
local function startRun(src, orderId)
    started['pf-mechanicjob'] = true
    Mock.exportsByResource['pf-mechanicjob'] = { StartSuppliesPickup = function() return true end }
    local stores = Mock.exportsByResource['pf-stores']
    stores.GetOrder = function(_, id) return { buyer_kind = 'jobbiz', store_id = 'mechanic', status = 'ready', items_json = '[]' } end
    local res = call(src, 'business:supplies:orders:pickup', { orderId = orderId, mode = 'job' })
    started['pf-mechanicjob'] = nil
    Mock.exportsByResource['pf-mechanicjob'] = nil
    stores.GetOrder = nil
    assert(res and res.ok, 'pickup run start: ' .. tostring(res and res.error))
end

describe('pf-computer security fixes', function()
    it('a domain goes only to a real character, under the name the server knows (not one typed in)', function()
        buyDomain(CITIZEN, 'site.ls')
        for _, e in ipairs(call(WORKER, 'browser:domains:list').data) do assert_eq(e.ownerIdentifier, nil, 'no citizen ids for other players') end
        assert_eq(call(CITIZEN, 'browser:domain:transfer', { domain = 'site.ls', targetIdentifier = 'NOBODY', targetName = 'Mayor' }).error, 'target_not_found')
        assert_eq(call(WORKER, 'browser:domain:transfer', { domain = 'site.ls', targetIdentifier = 'WORK1' }).error, 'not_owner')
        local ok = call(CITIZEN, 'browser:domain:transfer', { domain = 'site.ls', targetIdentifier = STAFF, targetName = 'Fake Name' })
        assert_true(ok.ok)
        assert_eq(ok.data.ownerName, 'Test Player4')
        for _, e in ipairs(call(STAFF, 'browser:domains:list').data) do
            if e.domain == 'site.ls' then assert_true(e.isOwner) end
        end
    end)
    it('a website is bounded plain data', function()
        buyDomain(CITIZEN, 'big.ls')
        assert_eq(call(CITIZEN, 'browser:website:save', { domain = 'big.ls', state = { pages = { home = { body = string.rep('x', 70000) } } } }).error, 'website_too_large')
        local deep = {}
        local t = deep
        for _ = 1, 10 do t.x = {} t = t.x end
        assert_eq(call(CITIZEN, 'browser:website:save', { domain = 'big.ls', state = deep }).error, 'website_too_large')
        local wide = {}
        for i = 1, 100 do wide['k' .. i] = 'v' end
        assert_eq(call(CITIZEN, 'browser:website:save', { domain = 'big.ls', state = wide }).error, 'website_too_large')
        local res = call(CITIZEN, 'browser:website:save', { domain = 'big.ls', state = { branding = { siteName = 'Mine' }, owner = { identifier = 'SOMEONE' } } })
        assert_true(res.ok)
        assert_eq(res.data.owner.identifier, nil)
        assert_eq(call(WORKER, 'browser:website:save', { domain = 'big.ls', state = {} }).error, 'not_owner')
    end)
    it('business settings: the blip goes where the boss stands, and values are checked', function()
        Mock.coords[BOSS] = vector3(100.0, 100.0, 20.0)
        assert_eq(call(BOSS, 'business:update:settings', { blipCoords = { x = 900.0, y = 900.0, z = 20.0 } }).error, 'invalid_coords')
        assert_eq(call(BOSS, 'business:update:settings', { blipColor = 9999 }).error, 'invalid_color')
        assert_eq(call(BOSS, 'business:update:settings', { logoUrl = 'javascript:alert(1)' }).error, 'invalid_logo')
        assert_true(call(BOSS, 'business:update:settings', { name = 'Shop', blipCoords = { x = 101.0, y = 100.0, z = 20.0 } }).ok)
        assert_eq(call(WORKER, 'business:update:settings', { name = 'Mine now' }).error, 'not_authorized')
    end)
    it('dark-web chat: the handle is the server\'s, staff can remove messages, the fake market is gone', function()
        local a = call(CITIZEN, 'darkweb:chat:post', { room = 'market', message = 'one', author = 'BOSS1' })
        assert_true(a.ok)
        assert_true(a.data.author ~= 'BOSS1')
        assert_true(a.data.author:match('^anon%-%x+$') ~= nil)
        Mock.clock = Mock.clock + 10
        assert_eq(call(CITIZEN, 'darkweb:chat:post', { room = 'market', message = 'two', author = 'other' }).data.author, a.data.author, 'same character, same handle')
        assert_true(call(WORKER, 'darkweb:chat:post', { room = 'market', message = 'three' }).data.author ~= a.data.author)
        assert_eq(call(CITIZEN, 'darkweb:chat:post', { room = 'market', message = 'spam' }).error, 'slow_down')
        assert_eq(call(CITIZEN, 'darkweb:chat:delete', { room = 'market', messageId = a.data.id }).error, 'not_authorized')
        Mock.aces[STAFF] = { ['pf-computer.admin'] = true }
        assert_true(call(STAFF, 'darkweb:chat:delete', { room = 'market', messageId = a.data.id }).ok)
        for _, m in ipairs(call(CITIZEN, 'darkweb:chat:join', { room = 'market' }).data.messages) do assert_true(m.id ~= a.data.id) end
        assert_eq(call(CITIZEN, 'darkweb:market:create', { title = 'x', price = '1 BTC' }).error, 'unknown_action')
        assert_eq(call(CITIZEN, 'darkweb:market:list').error, 'unknown_action')
    end)
    it('the job board takes the applicant from the server, never the typed name', function()
        local inserts = {}
        local realMode = PFComputer.DB.mode
        local single, insert = MySQL.single.await, MySQL.insert.await
        PFComputer.DB.mode = 'ready'
        MySQL.single.await = function(q, p)
            if q:find('FROM pf_computer_job_posts') then return { id = 7, status = 'open', business_kind = 'job', business_id = 'mechanic', hire_job = 'mechanic', poster_cid = 'BOSS1', title = 'Mechanic', business_name = 'LS Customs' } end
            return nil
        end
        MySQL.insert.await = function(q, p) inserts[#inserts + 1] = { q = q, p = p } return 11 end
        local ok, err = pcall(function()
            local res = call(CITIZEN, 'jobs:apply', { jobId = 7, name = 'The Mayor', phone = '911', email = 'x@y' })
            assert_true(res.ok)
            assert_eq(inserts[1].p[2], 'CIT1')
            assert_eq(inserts[1].p[3], 'Test Player3')
            assert_eq(res.data.name, 'Test Player3')
            assert_eq(mails[1].cid, 'BOSS1', 'the boss is told')
            assert_eq(call(BOSS, 'jobs:apply', { jobId = 7 }).error, 'own_business')
            assert_eq(call(CITIZEN, 'jobs:create', { title = 'Free money', company = 'LS Customs' }).error, 'not_business_manager')
        end)
        PFComputer.DB.mode, MySQL.single.await, MySQL.insert.await = realMode, single, insert
        assert(ok, err)
    end)
    it('the job board refuses when its tables are not there', function()
        assert_eq(call(CITIZEN, 'jobs:apply', { jobId = 1 }).error, 'storage_unavailable')
        assert_eq(call(CITIZEN, 'jobs:list').error, 'storage_unavailable')
    end)
end)

describe('pf-computer fakes removed', function()
    it('staff changes are real and follow the boss-menu rules', function()
        assert_eq(call(WORKER, 'business:employees:update', { employeeId = 'BOSS1', grade = 0 }).error, 'not_authorized')
        assert_eq(call(BOSS, 'business:employees:update', { employeeId = 'WORK1', grade = 4 }).error, 'grade_above_yours')
        assert_eq(call(BOSS, 'business:employees:update', { employeeId = 'CIT1', grade = 1 }).error, 'employee_not_found', 'not their staff')
        local res = call(BOSS, 'business:employees:update', { employeeId = 'WORK1', grade = 2 })
        assert_true(res.ok)
        assert_eq(Mock.players[WORKER].PlayerData.job.grade.level, 2)
        setJob(Mock.players[WORKER], 'mechanic', 4)
        assert_eq(call(BOSS, 'business:employees:fire', { employeeId = 'WORK1' }).error, 'outranks_you')
        setJob(Mock.players[WORKER], 'mechanic', 1)
        assert_true(call(BOSS, 'business:employees:fire', { employeeId = 'WORK1' }).ok)
        assert_eq(Mock.players[WORKER].PlayerData.job.name, 'unemployed')
        local list = call(BOSS, 'business:employees:list')
        for _, e in ipairs(list.data) do assert_eq(e.performance, nil) end
    end)
    it('stock is what the stash holds; no random numbers; no client-sent sales', function()
        stash['bizstash-mechanic'] = { { name = 'engine_oil', label = 'Oil', amount = 7 } }
        for _ = 1, 3 do assert_eq(call(BOSS, 'business:inventory:get', { item = 'engine_oil' }).stock, 7) end
        assert_eq(call(BOSS, 'business:inventory:get', { item = 'tyre' }).stock, 0)
        assert_eq(call(BOSS, 'business:transactions:add', { total = 1000000 }).error, 'unknown_action')
        assert_eq(call(BOSS, 'business:analytics', { period = 'week' }).error, 'records_unavailable', 'no figures without the records')
    end)
    it('wages are paid by pfm-core: saved only when the job grades took them', function()
        assert_eq(call(BOSS, 'business:wages:set', { wages = { ['1'] = 90 } }).error, 'payroll_unavailable')
        local updated
        Mock.exportsByResource['pfm-core'].UpdateJob = function(_, job, def) updated = def return true end
        assert_true(call(BOSS, 'business:wages:set', { wages = { ['1'] = 90 } }).ok)
        assert_eq(updated.grades['1'].payment, 90)
        assert_eq(call(BOSS, 'business:wages:set', { wages = { ['1'] = 500 } }).error, 'cap_exceeded')
        assert_eq(call(BOSS, 'business:wages:set', { wages = { ['1'] = -5 } }).error, 'invalid_wage')
        Mock.exportsByResource['pfm-core'].UpdateJob = nil
    end)
    it('item pictures come from pfm-inventory', function()
        Mock.exportsByResource['pf-mechanicjob'] = {
            GetBusinessConfig = function() return { suppliesCatalog = { items = { { item = 'engine_oil', label = 'Oil', pricePerCase = 5 } } } } end,
        }
        started['pf-mechanicjob'] = true
        local res = call(BOSS, 'business:supplies:catalog', { mode = 'job' })
        started['pf-mechanicjob'] = nil
        Mock.exportsByResource['pf-mechanicjob'] = nil
        assert_true(res.ok)
        assert_eq(res.data.catalog.imageBase, 'https://cfx-nui-pfm-inventory/html/images/')
    end)
    it('the Store offers the business apps to whom the server allows them', function()
        local a = call(BOSS, 'business:access').data
        assert_true(a.business and a.isBoss)
        local c = call(CITIZEN, 'business:access').data
        assert_false(c.business)
        assert_false(c.isBoss)
    end)
end)

describe('pf-computer mail and City Hall', function()
    it('City Hall notices are left to pf-citizen (which mails every citizen itself): no second copy', function()
        TriggerEvent('pf-computer:gov:laws:sync', { action = 'publish', law = { id = 3, title = 'No Racing', content = 'Do not race.' } })
        TriggerEvent('pf-computer:gov:announcements:sync', { action = 'create', announcement = { id = 9, title = 'Road works', body = 'Closed' } })
        assert_eq(#everyone + #mails, 0)
        assert_eq(Mock.netHandlers['pf-computer:gov:laws:sync'], nil, 'not a net event')
        -- the law list copy still follows pf-government
        started['pf-government'] = false
        local laws = call(CITIZEN, 'gov:laws:list').data
        started['pf-government'] = true
        assert_eq(laws[1].title, 'No Racing')
    end)
    it('a computer announcement is posted through pf-government as the player', function()
        assert_eq(call(CITIZEN, 'gov:announcements:create', { title = 'x' }).error, 'not_authorized')
        govPerms[STAFF] = { laws = true }
        assert_true(call(STAFF, 'gov:announcements:create', { title = 'Parade', body = 'Sunday', priority = 'mega' }).ok)
        assert_eq(announcements[1].src, STAFF)
        assert_eq(announcements[1].data.priority, 'normal')
    end)
end)

describe('pf-computer pickup runs', function()
    it('a finished run collects the shared order once, whichever event pf-mechanicjob raises first', function()
        Mock.players[BOSS].PlayerData.job.isboss = true
        startRun(BOSS, 42)
        TriggerEvent('pf-computer:server:supplies:orderDelivered', 42, BOSS)
        TriggerEvent('pf-computer:server:supplies:completeOrder', BOSS, 42)
        assert_eq(#collected, 1)
        assert_eq(collected[1].buyerId, 'mechanic')
        TriggerEvent('pf-computer:server:supplies:completeOrder', WORKER, 42)
        assert_eq(#collected, 1, 'another player cannot finish it')
    end)
end)
