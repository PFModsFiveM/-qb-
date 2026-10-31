-- pf-computer's shared apps on pf-devices (server/devices.lua): Business Manager, Order Supplies and
-- the Job Board register for the tablet and the computer; who sees them is decided by the same
-- functions the computer's actions use; every RPC reaches the real action with the player's own
-- source and passes the same boss / government / storage checks; positions come from the server.
-- Also: the lock screen and desktop layout kept per character (server/profiles.lua), the registry
-- reads through pf-government's exports, restaurant hiring through pf-restaurants, and the clean-up
-- when a character is deleted (server/characters.lua).
load_resource('tests/lua/fivem_mocks.lua')

local started = {
    ['pfm-core'] = true, ['pf-devices'] = true, ['pf-government'] = true, ['pfm-inventory'] = true,
    ['pf-stores'] = true, ['pf-citizen'] = true, ['pf-restaurants'] = false, ['pfm-banking'] = false,
}
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

local govPerms, registryRows, ownedBy = {}, {}, {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return govPerms[src] ~= nil and govPerms[src][perm] == true end,
    ListBusinesses = function() return registryRows end,
    GetBusinessesOwnedBy = function(_, owners) return ownedBy[owners[1]] or {} end,
    GetBusinessEmployees = function(_, id) return { ok = true, employees = { { name = 'Staff of ' .. id, role = 'cashier' } } } end,
    TransferBusinessOwnershipAs = function(_, src, id, ownerId) return govPerms[src] and govPerms[src].businesses == true, 'no_permission' end,
}
Mock.exportsByResource['pf-citizen'] = { SendMail = function() return true end }
local stash = {}
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function() return true end,
    GetInventory = function(_, id) return { items = stash[id] or {} } end,
    GetFreshness = function() return nil end,
}
local OWNER = 6
local seenStores = {}
Mock.exportsByResource['pf-stores'] = {
    RegisterBuyerKind = function() return true end,
    ListOwnedStores = function(_, src) return { ok = true, data = { stores = src == OWNER and { { storeId = 's1', label = 'Corner' } } or {} } } end,
    GetOrderSuppliesConfig = function(_, src, p) seenStores[#seenStores + 1] = { src = src, payload = p } return { ok = true, data = { businessName = 'Corner' } } end,
    GetStoreBalance = function() return { ok = true, data = { balance = 10 } } end,
}
local restaurantStaff = {}
Mock.exportsByResource['pf-restaurants'] = {
    GetRestaurantForJob = function() return nil end,
    GetStaffRoles = function() return { { id = 'employee', label = 'Employee' }, { id = 'cashier', label = 'Cashier' }, { id = 'owner', label = 'Owner' } } end,
    IsEmployeeOf = function() return false end,
    AddStaff = function(_, rid, cid, role, by) restaurantStaff[#restaurantStaff + 1] = { rid = rid, cid = cid, role = role, by = by } return true end,
}

-- pushes and app registrations as pf-computer makes them
local pushes = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) return PFDevices.RegisterApp(def, 'pf-computer') end,
    RegisterAppHandlers = function(_, id, map) return PFDevices.RegisterAppHandlers(id, map, 'pf-computer') end,
    Push = function(_, src, app, event) pushes[#pushes + 1] = { kind = 'player', target = src, app = app, event = event } return true end,
    PushToCitizen = function(_, cid, app, event) pushes[#pushes + 1] = { kind = 'citizen', target = cid, app = app, event = event } return true end,
    PushToJob = function(_, job, app, event) pushes[#pushes + 1] = { kind = 'job', target = job, app = app, event = event } return 1 end,
    Broadcast = function(_, app, event) pushes[#pushes + 1] = { kind = 'all', app = app, event = event } return true end,
}

Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
load_resource('[pfscripts]/pf-computer/config/config_hack.lua')
load_resource('[pfscripts]/pf-computer/config/config_dark.lua')
load_resource('[pfscripts]/pf-devices/shared/config.lua')
Config.Rpc.burst, Config.Rpc.perSecond = 100000, 100000
load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/rpc.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')
for _, f in ipairs({ 'main', 'jobboard', 'registry', 'profiles', 'characters', 'devices' }) do
    load_resource('[pfscripts]/pf-computer/server/' .. f .. '.lua')
end
local C = PFComputer

local BOSS, LEAD, WORKER, CITIZEN, OFFICIAL = 1, 2, 3, 4, 5
local function setJob(p, name, grade)
    local j = QBCoreMock.Shared.Jobs[name]
    local g = j and j.grades[tostring(grade)]
    if not g then return false end
    p.PlayerData.job = { name = name, label = j.label, grade = { level = tonumber(grade), name = g.name }, isboss = g.isboss == true, onduty = true }
    return true
end
local function player(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.Functions = p.Functions or {}
    p.Functions.SetJob = function(name, gr) return setJob(p, name, gr) end
    p.Functions.Save = function() end
    p.Functions.GetItemByName = function(name) return (p.PlayerData.tools or {})[name] and { amount = 1 } or nil end
    setJob(p, job, grade)
    return p
end
local function rpc(src, app, method, payload) return PFDevices.HandleRpc(src, app, method, payload) end
local function appIds(src, device)
    local out = {}
    for _, a in ipairs(PFDevices.GetAppsFor(src, device).apps) do out[a.id] = true end
    return out
end
local function eventsTo(name, src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if e.target == src then n = n + 1 end end
    return n
end
--- Wraps a computer action to see who called it with what (the real action still runs).
local function spy(action)
    local seen = {}
    local real = C.handlers[action]
    C.handlers[action] = function(payload, src) seen[#seen + 1] = { src = src, payload = payload } return real(payload, src) end
    return seen, function() C.handlers[action] = real end
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    pushes, govPerms, registryRows, ownedBy, restaurantStaff, seenStores = {}, {}, {}, {}, {}, {}
    PFDevices.__reset()
    PFDevices.__resetRpc()
    assert(PFComputerRegisterApps(), 'apps registered')
    player(BOSS, 'BOSS1', 'mechanic', 4)
    player(LEAD, 'LEAD1', 'mechanic', 3)
    player(WORKER, 'WORK1', 'mechanic', 1)
    player(CITIZEN, 'CIT1', 'unemployed', 0)
    player(OFFICIAL, 'GOV1', 'unemployed', 0)
    player(OWNER, 'OWN6', 'unemployed', 0)
    govPerms[OFFICIAL] = { businesses = true }
end

describe('pf-computer apps on pf-devices', function()
    it('registers the three shared apps for the tablet and the computer, in the business category', function()
        for _, id in ipairs({ 'businessmanager', 'ordersupplies', 'jobboard' }) do
            local app = PFDevices.GetApp(id)
            assert_true(app ~= nil, id)
            assert_eq(table.concat(app.devices, ','), 'computer,tablet')
            assert_eq(app.category, 'business')
            assert_eq(app.resource, 'pf-computer')
            assert_eq(app.entry, 'html/apps/' .. id .. '.js')
        end
        assert_true(PFDevices.GetApp('businessmanager').access.handler)
        assert_true(PFDevices.GetApp('ordersupplies').access.handler)
        assert_true(PFDevices.GetApp('jobboard').access.anyone)
        -- the pf-government launchers stay computer-only
        assert_eq(table.concat(PFDevices.GetApp('cityhall-businesses').devices, ','), 'computer')
    end)

    it('shows each app to exactly the players the computer actions serve', function()
        local boss, lead, worker, citizen = appIds(BOSS, 'tablet'), appIds(LEAD, 'tablet'), appIds(WORKER, 'tablet'), appIds(CITIZEN, 'tablet')
        assert_true(boss.businessmanager and boss.ordersupplies and boss.jobboard, 'the boss gets all three')
        assert_true(lead.businessmanager and lead.ordersupplies, 'a configured manager rank (mechanic grade 2+) manages the business')
        assert_true(worker.businessmanager == nil and worker.ordersupplies == nil and worker.jobboard, 'a mechanic below the rank: Job Board only')
        assert_true(citizen.businessmanager == nil and citizen.ordersupplies == nil and citizen.jobboard)
        local official, owner = appIds(OFFICIAL, 'computer'), appIds(OWNER, 'computer')
        assert_true(official.businessmanager and official.ordersupplies == nil, 'government staff see the registry part only')
        assert_true(owner.ordersupplies and owner.businessmanager == nil, 'a store owner orders for the store')
    end)

    it('every RPC reaches the real action with the player\'s own source', function()
        local seen, undo = spy('business:getData')
        assert_eq(rpc(BOSS, 'businessmanager', 'data', { businessId = 'mechanic' }).ok, true)
        undo()
        assert_eq(#seen, 1)
        assert_eq(seen[1].src, BOSS)
        assert_eq(seen[1].payload.businessId, 'mechanic')
        local seenJobs, undoJobs = spy('jobs:myApplications')
        rpc(CITIZEN, 'jobboard', 'myApplications')
        undoJobs()
        assert_eq(seenJobs[1].src, CITIZEN)
        local seenCat, undoCat = spy('business:supplies:catalog')
        rpc(OWNER, 'ordersupplies', 'catalog', { mode = 'store', storeId = 's1', price = 1 })
        undoCat()
        assert_eq(seenCat[1].src, OWNER)
        assert_eq(seenCat[1].payload.mode, 'store')
        assert_eq(seenCat[1].payload.price, nil, 'only the fields the action reads are passed on')
        assert_eq(seenStores[1].src, OWNER, 'pf-stores checks ownership with the real source')
        -- the first screen comes in one call, each part through its own action
        local init = rpc(BOSS, 'businessmanager', 'init')
        assert_true(init.business and init.config.ok and init.employees.ok)
        assert_false(init.registry)
    end)

    it('refuses players who may not use an app, and keeps the boss-only and government-only checks', function()
        assert_eq(rpc(CITIZEN, 'businessmanager', 'data').error, 'not_authorized')
        assert_eq(rpc(WORKER, 'ordersupplies', 'catalog').error, 'not_authorized')
        assert_eq(rpc(CITIZEN, 'businessmanager', '__access').error, 'unknown_method', 'the access check is not callable')
        -- a manager (not the boss) opens the app but cannot change what only the boss changes
        for _, m in ipairs({ 'menuAdd', 'mealAdd', 'employeeFire', 'employeeGrade', 'wagesSet', 'stashHere', 'settings' }) do
            assert_eq(rpc(LEAD, 'businessmanager', m, { item = { name = 'x', price = 1 }, employeeId = 'WORK1', grade = 2 }).error, 'not_authorized', m)
        end
        assert_eq(rpc(LEAD, 'businessmanager', 'withdraw', { amount = 10 }).error, 'not_boss')
        assert_eq(rpc(LEAD, 'ordersupplies', 'create', { items = { { item = 'x', quantity = 1 } } }).error, 'not_authorized')
        -- the registry needs the government permission, also for a business boss
        assert_eq(rpc(BOSS, 'businessmanager', 'registry').error, 'not_authorized')
        assert_eq(rpc(BOSS, 'businessmanager', 'registryTransfer', { businessId = 'store:1', ownerId = 'BOSS1' }).error, 'not_authorized')
    end)

    it('places stash points and blips where the boss stands (read on the server), never at sent coordinates', function()
        Mock.coords[BOSS] = vector3(100.0, 200.0, 30.0)
        local res = rpc(BOSS, 'businessmanager', 'stashHere', { coords = { x = -2000.0, y = -2000.0, z = 0.0 } })
        assert_true(res.ok, tostring(res.error))
        local loc = C.dataStore.businesses.mechanic.stashLocations[1]
        assert_near(loc.x, 100.0, 0.01)
        assert_near(loc.y, 200.0, 0.01)
        res = rpc(BOSS, 'businessmanager', 'blipHere', { name = 'Shop', color = 3, coords = { x = 9999.0, y = 9999.0, z = 0.0 } })
        assert_true(res.ok, tostring(res.error))
        assert_near(res.data.coords.x, 100.0, 0.01)
    end)

    it('starts the delivery point placement only for the boss, putting the device away first', function()
        assert_eq(rpc(LEAD, 'ordersupplies', 'deliveryPoint').error, 'not_boss')
        assert_eq(eventsTo('pf-computer:client:placeDeliveryPoint', LEAD), 0)
        assert_true(rpc(BOSS, 'businessmanager', 'deliveryPoint').ok)
        assert_eq(eventsTo('pf-devices:client:closeShells', BOSS), 1)
        assert_eq(eventsTo('pf-computer:client:placeDeliveryPoint', BOSS), 1)
    end)

    it('the city registry comes from pf-government\'s registry exports, not its table', function()
        registryRows = { { id = 'store:1', name = 'Corner Store', type = 'store', ownerId = 'OWN6', ownerName = 'Olga', status = 'active', license = 'active', compliance = 'compliant' },
            { id = 'mechanic:mechanic', name = 'LS Customs', type = 'mechanic', ownerId = 'job:mechanic', status = 'closed', license = 'none' } }
        local res = rpc(OFFICIAL, 'businessmanager', 'registry')
        assert_true(res.ok, tostring(res.error))
        assert_eq(#res.businesses, 2)
        assert_eq(res.businesses[1].owner, 'Olga')
        assert_true(res.businesses[1].transferable)
        assert_false(res.businesses[2].transferable, 'job shops belong to their job')
        assert_eq(res.stats.activeBusinesses, 1)
        for _, call in ipairs(Mock.dbCalls) do
            assert_eq(tostring(call.query):find('pf_gov_businesses', 1, true), nil, 'no direct read of the registry table')
        end
        assert_eq(rpc(OFFICIAL, 'businessmanager', 'registryEmployees', { businessId = 'store:1' }).employees[1].name, 'Staff of store:1')
        assert_eq(rpc(OFFICIAL, 'businessmanager', 'registryEmployees', { businessId = 'bad id' }).error, 'business_not_found')
    end)

    it('a restaurant owner on the registry posts with the restaurant\'s staff roles (never the owner role)', function()
        started['pf-restaurants'] = true
        ownedBy['OWN6'] = { { id = 'restaurant:bs', name = 'Burger Shot', ownerId = 'OWN6' }, { id = 'store:x', name = 'Not mine', ownerId = 'SOMEONE' } }
        local res = rpc(OWNER, 'jobboard', 'businesses')
        started['pf-restaurants'] = false
        assert_true(res.ok)
        assert_eq(#res.data, 1, 'only businesses the export says they own')
        assert_eq(res.data[1].key, 'gov:restaurant:bs')
        assert_true(res.data[1].hires)
        assert_eq(res.data[1].hireKind, 'restaurant')
        local ids = {}
        for _, r in ipairs(res.data[1].roles) do ids[#ids + 1] = r.id end
        assert_eq(table.concat(ids, ','), 'employee,cashier')
    end)

    it('rank changes and firing use pfm-management\'s staff rules when it runs', function()
        local calls = {}
        Mock.exportsByResource['pfm-management'] = {
            SetEmployeeGrade = function(_, src, cid, grade, scope) calls[#calls + 1] = { 'grade', src, cid, grade, scope } return cid == 'WORK1', 'not_member' end,
            FireEmployee = function(_, src, cid, scope) calls[#calls + 1] = { 'fire', src, cid, scope } return false, 'outranks_you' end,
        }
        started['pfm-management'] = true
        local up = rpc(BOSS, 'businessmanager', 'employeeGrade', { employeeId = 'WORK1', grade = 2 })
        local stranger = rpc(BOSS, 'businessmanager', 'employeeGrade', { employeeId = 'CIT1', grade = 1 })
        local fire = rpc(BOSS, 'businessmanager', 'employeeFire', { employeeId = 'LEAD1' })
        started['pfm-management'] = false
        Mock.exportsByResource['pfm-management'] = nil
        assert_true(up.ok)
        assert_eq(up.data.rank, 'Senior')
        assert_eq(stranger.error, 'employee_not_found')
        assert_eq(fire.error, 'outranks_you')
        assert_eq(table.concat({ calls[1][1], calls[1][2], calls[1][3], calls[1][4], calls[1][5] }, ','), 'grade,1,WORK1,2,job')
        assert_eq(calls[3][2], BOSS, 'with the boss\'s own source')
        -- without pfm-management the computer applies the same rules itself
        assert_eq(rpc(BOSS, 'businessmanager', 'employeeGrade', { employeeId = 'CIT1', grade = 1 }).error, 'employee_not_found')
        assert_eq(rpc(BOSS, 'businessmanager', 'employeeGrade', { employeeId = 'BOSS1', grade = 1 }).error, 'cannot_change_self')
    end)

    it('pushes staff changes to the job and new duty to open Business Managers', function()
        C.push('job', 'mechanic', 'businessmanager', 'staff', {})
        assert_eq(pushes[#pushes].target, 'mechanic')
        pushes = {}
        TriggerEvent('QBCore:Server:SetDuty', BOSS, false)
        assert_eq(#pushes, 1)
        assert_eq(pushes[1].kind, 'job')
        assert_eq(pushes[1].app, 'businessmanager')
        assert_eq(pushes[1].event, 'staff')
    end)
end)

describe('pf-computer lock screen and desktop, kept per character', function()
    local SCOPE = 'profile:default:model:-123:pos:1.5,2,3'
    local function lockCall(src, action, payload)
        payload = payload or {}
        payload.scope = payload.scope or SCOPE
        return C.dispatch(action, payload, src)
    end

    it('SHA-256 is correct (the PIN hash)', function()
        assert_eq(C.sha256(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
        assert_eq(C.sha256('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        assert_eq(C.sha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'), '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
    end)

    it('a lock needs a PIN; the PIN is checked on the server and never sent back', function()
        assert_eq(lockCall(CITIZEN, 'security:lock:settings', { enabled = true, method = 'pin' }).error, 'pin_required')
        assert_eq(lockCall(CITIZEN, 'security:lock:settings', { enabled = true, method = 'pin', pin = '12a4' }).error, 'bad_pin')
        local res = lockCall(CITIZEN, 'security:lock:settings', { enabled = true, method = 'pin', pin = '2468' })
        assert_true(res.ok)
        assert_true(res.security.hasPin)
        for k, v in pairs(res.security) do
            assert_false(k == 'pin' or k == 'salt' or (type(v) == 'string' and #v == 64), 'no secret in ' .. k)
        end
        assert_eq(lockCall(CITIZEN, 'profile:get').security.locked, false)
        assert_true(lockCall(CITIZEN, 'security:lock:lock').security.locked)
        -- another character on the same computer has its own lock screen
        assert_false(lockCall(BOSS, 'security:lock:state').security.locked)
        -- wrong PIN: counted, then a timeout; the right PIN does not open it during the timeout
        local wrong = lockCall(CITIZEN, 'security:lock:unlock', { secret = '1111' })
        assert_eq(wrong.error, 'wrong_secret')
        assert_eq(wrong.security.attemptsLeft, 4)
        assert_eq(wrong.security.timeoutRemaining, 10)
        assert_eq(lockCall(CITIZEN, 'security:lock:unlock', { secret = '2468' }).error, 'timeout')
        assert_eq(lockCall(CITIZEN, 'security:lock:settings', { enabled = false }).error, 'locked', 'settings cannot switch the lock off while locked')
        Mock.clock = Mock.clock + 11
        local ok = lockCall(CITIZEN, 'security:lock:unlock', { secret = '2468' })
        assert_true(ok.ok)
        assert_false(ok.security.locked)
        assert_eq(ok.security.fails, 0)
    end)

    it('a breach needs the tool; failures lead to a lockdown that the lockdown password ends', function()
        lockCall(CITIZEN, 'security:lock:settings', { enabled = true, method = 'password', password = 'hunter22', lockdownOnHackFail = true, lockdownThreshold = 2, lockdownPassword = 'admin99' })
        lockCall(CITIZEN, 'security:lock:lock')
        assert_eq(lockCall(CITIZEN, 'security:lock:breach', { tier = 'basic', success = true }).error, 'missing_tool')
        Mock.players[CITIZEN].PlayerData.tools = { hack_usb_basic = true }
        assert_eq(lockCall(CITIZEN, 'security:lock:breach', { tier = 'nope', success = true }).error, 'invalid_tier')
        assert_eq(lockCall(CITIZEN, 'security:lock:breach', { tier = 'basic', success = false }).error, 'breach_failed')
        local down = lockCall(CITIZEN, 'security:lock:breach', { tier = 'basic', success = false })
        assert_eq(down.error, 'lockdown')
        assert_eq(down.security.lockdownRemaining, 600)
        assert_eq(lockCall(CITIZEN, 'security:lock:unlock', { secret = 'hunter22' }).error, 'lockdown')
        assert_eq(lockCall(CITIZEN, 'security:lock:exitLockdown', { password = 'wrong' }).error, 'wrong_secret')
        Mock.clock = Mock.clock + 11
        assert_true(lockCall(CITIZEN, 'security:lock:exitLockdown', { password = 'admin99' }).ok)
        assert_true(lockCall(CITIZEN, 'security:lock:breach', { tier = 'basic', success = true }).ok)
        assert_false(lockCall(CITIZEN, 'security:lock:state').security.locked)
    end)

    it('the desktop layout keeps only bounded desktop fields, and bad scopes are refused', function()
        local items = { { id = 'browser', app = 'browser', type = 'app', location = 'desktop', position = { x = 3, y = 999 }, evil = '<script>' },
            { id = 'bad id with spaces', type = 'app' }, { id = 'doc_1', type = 'document', title = 'My\nDoc', documentId = 7 } }
        for i = 1, 200 do items[#items + 1] = { id = 'x' .. i, type = 'app' } end
        assert_true(lockCall(CITIZEN, 'profile:layout:save', { items = items, folders = { { id = 'f1', name = string.rep('n', 100) } } }).ok)
        local layout = lockCall(CITIZEN, 'profile:get').layout
        assert_eq(#layout.items, 150)
        assert_eq(layout.items[1].evil, nil)
        assert_eq(layout.items[1].position.y, 199)
        assert_eq(layout.items[2].id, 'doc_1', 'an id that is not a plain token is dropped')
        assert_eq(layout.items[2].documentId, '7')
        assert_eq(layout.items[2].title, 'My Doc')
        assert_eq(#layout.folders[1].name, 60)
        assert_eq(lockCall(CITIZEN, 'profile:get', { scope = 'bad scope "x"' }).error, 'bad_scope')
        assert_eq(lockCall(BOSS, 'profile:get').layout, nil, 'each character has their own layout')
        assert_true(lockCall(CITIZEN, 'profile:layout:reset').ok)
        assert_eq(lockCall(CITIZEN, 'profile:get').layout, nil)
    end)
end)

describe('pf-computer when a character is deleted', function()
    it('forgets the character\'s private data and keeps what others need without the link', function()
        local data = C.dataStore
        data.pickupRuns['GONE1'] = { orderId = 5, businessId = 'mechanic', startedAt = 1 }
        data.browserDomains[#data.browserDomains + 1] = { domain = 'gone.ls', ownerIdentifier = 'GONE1', ownerName = 'Gone Person', templateId = 'services' }
        data.browserWebsites['gone.ls'] = { owner = { name = 'Gone Person' } }
        data.businesses.mechanic = data.businesses.mechanic or { id = 'mechanic', settings = {}, stashLocations = {} }
        data.businesses.mechanic.stashLocations[#data.businesses.mechanic.stashLocations + 1] = { x = 1, y = 2, z = 3, createdBy = 'GONE1' }
        data.chatRooms.market = { messages = { { id = 1, author = C.chatHandle('GONE1'), message = 'mine' }, { id = 2, author = C.chatHandle('OTHER'), message = 'theirs' } } }
        local p = player(9, 'GONE1', 'unemployed', 0)
        C.dispatch('security:lock:settings', { scope = 'default', enabled = true, method = 'pin', pin = '1234' }, 9)

        TriggerEvent('pfm-core:server:characterDeleted', nil)
        TriggerEvent('pfm-core:server:characterDeleted', '')
        assert_true(data.pickupRuns['GONE1'] ~= nil, 'a bad argument changes nothing')

        TriggerEvent('pfm-core:server:characterDeleted', 'GONE1')
        assert_eq(data.pickupRuns['GONE1'], nil)
        local domain
        for _, d in ipairs(data.browserDomains) do if d.domain == 'gone.ls' then domain = d end end
        assert_eq(domain.ownerIdentifier, 'deleted', 'the site stays for its visitors')
        assert_eq(data.browserWebsites['gone.ls'].owner.name, 'Former owner')
        assert_eq(data.businesses.mechanic.stashLocations[#data.businesses.mechanic.stashLocations].createdBy, nil)
        assert_eq(#data.chatRooms.market.messages, 1)
        assert_eq(data.chatRooms.market.messages[1].message, 'theirs')
        assert_false(C.dispatch('security:lock:state', { scope = 'default' }, 9).security.enabled, 'the lock screen is gone')
        assert_eq(p.PlayerData.citizenid, 'GONE1')
    end)

    it('with the database: deletes applications, chat, pickup run and profiles; anonymises posts', function()
        local mode = C.DB.mode
        C.DB.mode = 'ready'
        Mock.dbCalls = {}
        TriggerEvent('pfm-core:server:characterDeleted', 'GONE2')
        C.DB.mode = mode
        local seen = {}
        for _, call in ipairs(Mock.dbCalls) do
            local q = tostring(call.query):gsub('%s+', ' ')
            seen[#seen + 1] = q
            for _, v in ipairs(call.params or {}) do
                if v == 'GONE2' then seen[#seen] = seen[#seen] .. ' <cid>' end
            end
        end
        local all = table.concat(seen, '\n')
        assert_true(all:find('DELETE FROM pf_computer_job_applications WHERE applicant_cid = ? <cid>', 1, true) ~= nil, all)
        assert_true(all:find("UPDATE pf_computer_job_posts SET poster_cid = ?, poster_name = 'Former staff' WHERE poster_cid = ? <cid>", 1, true) ~= nil)
        assert_true(all:find('DELETE FROM pf_computer_chat WHERE citizenid = ? <cid>', 1, true) ~= nil)
        assert_true(all:find('DELETE FROM pf_computer_profiles WHERE citizenid = ? <cid>', 1, true) ~= nil)
        assert_true(all:find('DELETE FROM pf_computer_pickup_runs WHERE citizenid = ? <cid>', 1, true) ~= nil)
        assert_true(all:find('UPDATE pf_computer_job_applications SET decided_by = NULL WHERE decided_by = ? <cid>', 1, true) ~= nil)
    end)
end)
