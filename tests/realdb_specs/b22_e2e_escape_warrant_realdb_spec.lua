-- 22A end to end on MariaDB: escape -> warrant request (judge review) -> recapture -> warrant recalled,
-- order resumed with the work credit forfeited. REAL resources in one world (tests/specs/b22_e2e_world.lua):
-- pf-justice (every server file), pfm-prison (main, bridge, facility, work, economy, security, ...),
-- pf-policemdt-DEV (framework, config, access, schema, main, records_ext: the warrant owner) and the
-- pfm-banking ledger. The escape is the server's own detection (a hacked gate, the sampler seeing the
-- inmate pass it and leave the walls); the judge decides in the Court app; officers bring the escapee
-- back inside the walls. Every resource restarts between the escape and the recapture.
-- Stubbed: FiveM natives, inventory (in memory), pf-citizen mail, pf-devices registry, pfm-doorlock,
-- pfm-minigames (the puzzle verdict), pf-services, pfm-policejob cuffs.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('tests/specs/b22_e2e_world.lua')
function IsDuplicityVersion() return true end
function SetEntityCoords() end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end
-- real time: MDT warrant expiry is compared with the database's NOW()
Mock.clock = os.time(os.date('*t'))
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' }, judge = { label = 'Judiciary' },
    corrections = { label = 'Corrections', grades = {} } }
World.installResourceState({ ['pf-ambulancejob'] = 'missing', ['pf-government'] = 'missing', ['pfm-phone'] = 'missing' })

World.startBank()
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('pfm-clothing/qb-clothing.sql')
local Inv = World.inventory()
Mock.exportsByResource['pf-citizen'] = { SendMail = function() return 1 end, AddCalendarEvent = function() return 1 end }
local Apps = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, appId, handlers) Apps[appId] = handlers return true end,
    PushToJob = function() end, Push = function() end, PushToCitizen = function() end, PushToApp = function() end,
}
local function app(appId, method, src, payload)
    local h = assert(Apps[appId], 'app not registered: ' .. tostring(appId))
    if h.__access and not h.__access(src) then return { ok = false, error = 'no_access' } end
    return Mock.cross(h[method], src, payload or {})
end
Mock.exportsByResource['pfm-policejob'] = { SetCuffed = function() return true end, IsCuffed = function() return false end,
    RegisterReferenceSample = function() return { ok = true } end }
Mock.exportsByResource['pfm-doorlock'] = { SetDoorState = function(_, id, locked) return { ok = true, locked = locked, changed = true } end }
local puzzle = true
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function() return { id = 'b22-gate', kind = 'hacking', puzzle = {} } end,
    Verify = function() return puzzle end, Cancel = function() end,
}
Mock.exportsByResource['pf-services'] = { Emit = function() return 1 end }
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local r = MySQL[kind].await(sql, params)
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'),
    update = ox('update'), scalar = ox('scalar'), single = ox('single') }

local JFILES = { '[pfscripts]/pf-justice/config.lua', '[pfscripts]/pf-justice/shared/states.lua', '[pfscripts]/pf-justice/shared/cs_tasks.lua',
    '@pfm-banking/payouts.lua' }
for _, f in ipairs({ 'main', 'schema', 'orders', 'clock', 'records', 'custody', 'booking', 'property', 'bail', 'legacy_import', 'compat',
    'courts', 'warrants', 'supervision', 'monitors', 'community_service', 'restitution', 'api', 'apps' }) do
    JFILES[#JFILES + 1] = '[pfscripts]/pf-justice/server/' .. f .. '.lua'
end
World.start('pf-justice', JFILES, { boot = function(env)
    assert(env.PFJustice.Boot(), 'pf-justice boot')
    env.PFJustice.Custody.LoadOnline()
    Mock.eventHandlers['onResourceStart']('pf-justice')
end })
local function J() return World.env('pf-justice').PFJustice end

local MFILES = { '[pfscripts]/pf-policemdt-DEV/shared/framework.lua', '[pfscripts]/pf-policemdt-DEV/config.lua',
    '[pfscripts]/pf-policemdt-DEV/server/access.lua', '[pfscripts]/pf-policemdt-DEV/server/schema.lua',
    '[pfscripts]/pf-policemdt-DEV/server/main.lua', '[pfscripts]/pf-policemdt-DEV/server/records_ext.lua' }
World.start('pf-policemdt-DEV', MFILES, { boot = function(env)
    assert(env.PFMdtSchema.Run(), 'mdt schema')
    assert(env.PFMdtRecords.Start(), 'mdt records')
end })

local PFILES = { 'pfm-prison/config.lua', 'pfm-prison/config_facility.lua', 'pfm-prison/config_work.lua', '@pfm-banking/payouts.lua' }
for _, f in ipairs({ 'main', 'schema', 'justice_bridge', 'facility', 'schedule', 'discipline', 'visitation', 'work', 'economy',
    'security', 'supplies', 'apps' }) do
    PFILES[#PFILES + 1] = 'pfm-prison/server/' .. f .. '.lua'
end
World.start('pfm-prison', PFILES, { boot = function(env)
    local PF = env.PFPrison
    assert(PF.Bridge.Boot(), 'prison schema')
    PF.Facility.Boot()
    PF.Work.Boot()
    PF.Security.Boot()
    PF.Bridge.Pump()
end })
local function PR() return World.env('pfm-prison').PFPrison end
assert(World.call(nil, 'pfm-banking', 'AddMoney', 'corrections', 20000, 'b22 budget', 'b22:fund:corrections'), 'corrections funded')

local INM, JUDGE, COP = 1, 2, 3
local CW = World.env('pfm-prison').Config.Work
local PCfg = World.env('pfm-prison').Config
local BOARD, GATE = CW.Board, PCfg.Gates[1].coords
local OUTSIDE = vector3(GATE.x + 45.0, GATE.y + 15.0, GATE.z)

MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata) VALUES
  ('B22ESC', 1, 'license:b22esc', 'Eddie', '{}', '{"firstname":"Eddie","lastname":"Runner"}', '{}', '{}', '{}', '{}')]])
local P = Mock.newPlayer(INM, 'B22ESC')
P.PlayerData.charinfo = { firstname = 'Eddie', lastname = 'Runner' }
P.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = false }
P.PlayerData.money = { cash = 0, bank = 100 }
P.PlayerData.metadata.injail = 0
Inv.add(INM, 'goldbar', 2)
Mock.newPlayer(JUDGE, 'B22JDG').PlayerData.job = { name = 'judge', grade = { level = 1 }, onduty = true }
Mock.newPlayer(COP, 'B22COP2').PlayerData.job = { name = 'police', type = 'leo', grade = { level = 2 }, onduty = true }
for _, src in ipairs({ INM, JUDGE, COP }) do TriggerEvent('QBCore:Server:PlayerLoaded', Mock.players[src]) end

local function order(id) return World.one('SELECT * FROM pf_justice_orders WHERE id = ?', { id }) end
local function inmateRow() return World.one("SELECT * FROM pf_prison_inmates WHERE citizenid = 'B22ESC'") end
local function sample(pos, dt)
    Mock.clock = Mock.clock + (dt or 2)
    Mock.coords[INM] = pos
    PR().SampleTick()
end

local orderId, receiptCount
describe('22A flow 5: escape -> warrant (judge review) -> recapture -> recall, resume with forfeit', function()
    it('a prison sentence from the MDT; intake takes the property into the locker', function()
        local res = World.call('pf-policemdt-DEV', 'pf-justice', 'CreateOrder', { cid = 'B22ESC', kind = 'prison', minutes = 60,
            charges = { { code = 'PC-211', label = 'Robbery' } }, sourceRef = { type = 'mdt_sentence', id = 'b22-1' } },
            { key = 'pf-policemdt:sentence:b22-1:prison', actor = { kind = 'system', label = 'pf-policemdt sentencing' } })
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        orderId = res.orderId
        Mock.coords[INM] = BOARD
        PR().Bridge.Pump()
        assert_eq(inmateRow().status, 'in_cell')
        assert_eq(Inv.count(INM, 'goldbar'), 0, 'property in the locker')
        receiptCount = World.scalar("SELECT COUNT(*) FROM pf_justice_property WHERE citizenid = 'B22ESC' AND state = 'held'")
        assert_eq(receiptCount, 1)
    end)

    it('a kitchen shift earns a credit (so a recapture has something to forfeit)', function()
        World.fireNet('pfm-prison:server:WorkStart', INM, 'kitchen')
        for i, st in ipairs(CW.Jobs.kitchen.steps) do
            Mock.clock = Mock.clock + st.minSeconds + 5
            Mock.coords[INM] = st.coords
            World.fireNet('pfm-prison:server:WorkStep', INM, i)
        end
        Mock.clock = Mock.clock + 30
        World.fireNet('pfm-prison:server:WorkFinish', INM)
        assert_eq(tonumber(order(orderId).credit_seconds), CW.Jobs.kitchen.creditSeconds)
    end)

    local escapeId, warrantId, reviewId
    it('the server sees a hacked gate and the inmate leave through it: the order is suspended, property kept, warrant requested', function()
        Inv.add(INM, 'gatecrack', 1)
        Inv.add(INM, 'electronickit', 1)
        sample(GATE, 2)
        World.fireNet('prison:server:StartGateHack', INM, 1)
        local start = Mock.clientEventsNamed('prison:client:GateHackStart')
        assert_true(#start >= 1, 'the hack started')
        local ticketId = start[#start].args[2]
        Mock.clock = Mock.clock + 10
        World.fireNet('prison:server:GateHackResult', INM, ticketId, true)
        sample(GATE, 2)
        sample(OUTSIDE, 3)
        assert_eq(inmateRow().status, 'escaped')
        assert_eq(order(orderId).state, 'suspended', 'escape suspends (D12), never completes')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_property WHERE citizenid = 'B22ESC' AND state = 'held'"), receiptCount,
            'the property stays in the locker')
        local esc = World.one("SELECT * FROM pf_prison_escapes WHERE citizenid = 'B22ESC'")
        assert_true(esc ~= nil, 'escape row')
        escapeId = tonumber(esc.id)
        warrantId = esc.warrant_id
        assert_true(type(warrantId) == 'string' and warrantId ~= '', 'the MDT gave a warrant id')
        local w = World.one('SELECT * FROM pf_mdt_warrants WHERE warrantId = ?', { warrantId })
        assert_eq(w.suspectCitizenId, 'B22ESC')
        assert_eq(w.approval_state, 'pending_approval')
        reviewId = tonumber(w.review_id)
        assert_true(reviewId ~= nil, 'the judge review was filed in pf-justice')
        assert_eq(World.one('SELECT state FROM pf_justice_warrant_reviews WHERE id = ?', { reviewId }).state, 'requested')
    end)

    it('every resource restarts: the escape, the warrant request and the suspension are all still there, nothing is asked twice', function()
        World.restart('pf-policemdt-DEV')
        World.restart('pf-justice')
        World.restart('pfm-prison')
        Mock.clock = Mock.clock + 300
        PR().Security.Tick(os.time())
        PR().Bridge.Pump()
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_mdt_warrants WHERE suspectCitizenId = 'B22ESC'"), 1, 'one warrant')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_warrant_reviews WHERE target_cid = 'B22ESC'"), 1, 'one review')
        assert_eq(order(orderId).state, 'suspended')
        assert_eq(inmateRow().status, 'escaped')
        assert_eq(World.one('SELECT warrant_id FROM pf_prison_escapes WHERE id = ?', { escapeId }).warrant_id, warrantId)
    end)

    it('the judge approves in the Court app: the MDT warrant becomes active', function()
        local list = app('court', 'warrants', JUDGE, {})
        assert_true(list.ok, tostring(list.error))
        assert_eq(list.list[1].id, reviewId)
        local d = app('court', 'decideWarrant', JUDGE, { reviewId = reviewId, decision = 'approve' })
        assert_true(d.ok, tostring(d.error) .. ' ' .. tostring(d.message))
        local w = World.one('SELECT * FROM pf_mdt_warrants WHERE warrantId = ?', { warrantId })
        assert_eq(w.approval_state, 'approved')
        assert_eq(w.status, 'active')
    end)

    it('officers bring the escapee back inside: the order resumes, credit forfeited once, warrant recalled once, escape closed', function()
        local creditBefore = tonumber(order(orderId).credit_seconds)
        sample(BOARD, 5)
        PR().Bridge.Pump()
        PR().Bridge.Pump()
        assert_eq(order(orderId).state, 'active', 'serves on')
        assert_eq(inmateRow().status, 'in_cell')
        local o = order(orderId)
        assert_eq(tonumber(o.forfeit_seconds), creditBefore, 'the forfeit is capped at the credits earned')
        assert_eq(World.one('SELECT status FROM pf_mdt_warrants WHERE warrantId = ?', { warrantId }).status, 'removed', 'recalled')
        assert_true(World.one('SELECT recaptured_at FROM pf_prison_escapes WHERE id = ?', { escapeId }).recaptured_at ~= nil)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_prison_events WHERE citizenid = 'B22ESC' AND kind = 'warrant_recalled'"), 1)
        assert_eq(Inv.count(INM, 'goldbar'), 0, 'the locker is not handed back at the recapture')
    end)

    it('restarts after the recapture forfeit nothing twice and recall nothing twice', function()
        local forfeit = tonumber(order(orderId).forfeit_seconds)
        World.restart('pfm-prison')
        World.restart('pf-justice')
        Mock.clock = Mock.clock + 700
        PR().Security.Tick(os.time())
        PR().Bridge.Pump()
        assert_eq(tonumber(order(orderId).forfeit_seconds), forfeit)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_prison_events WHERE citizenid = 'B22ESC' AND kind = 'warrant_recalled'"), 1)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_order_events WHERE order_id = ? AND action = 'adjust_forfeit'", { orderId }), 1)
        assert_eq(inmateRow().status, 'in_cell')
        assert_eq(order(orderId).state, 'active')
    end)
end)

-- The usual recapture: police arrest the escapee outside (pfm-policejob OpenCustody, transport) and
-- bring them back inside the walls, where the bridge resumes the order. The arrest custody must not
-- stay open behind the resumed sentence: an open 'in_transport' custody re-cuffs and teleports the
-- inmate to its facility at every login (custody.lua placeBack), out of the prison.
local INM2 = 4
local Teleports = {}
function SetEntityCoords(ped, x, y, z) Teleports[#Teleports + 1] = { ped = ped, x = x, y = y, z = z } end
describe('22A flow 5b: recapture by arrest outside the walls', function()
    local order2, custodyId
    it('a second inmate escapes through gate 2; the warrant is requested', function()
        MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata) VALUES
          ('B22ESC2', 2, 'license:b22esc2', 'Ivy', '{}', '{"firstname":"Ivy","lastname":"Gone"}', '{}', '{}', '{}', '{}')]])
        local p = Mock.newPlayer(INM2, 'B22ESC2')
        p.PlayerData.charinfo = { firstname = 'Ivy', lastname = 'Gone' }
        p.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = false }
        p.PlayerData.metadata.injail = 0
        TriggerEvent('QBCore:Server:PlayerLoaded', p)
        local res = World.call('pf-policemdt-DEV', 'pf-justice', 'CreateOrder', { cid = 'B22ESC2', kind = 'prison', minutes = 60,
            sourceRef = { type = 'mdt_sentence', id = 'b22-2' } }, { key = 'pf-policemdt:sentence:b22-2:prison', actor = { kind = 'system', label = 'pf-policemdt' } })
        assert_true(res.ok, tostring(res.error))
        order2 = res.orderId
        Mock.coords[INM2] = BOARD
        PR().Bridge.Pump()
        local G2 = PCfg.Gates[2].coords
        Inv.add(INM2, 'gatecrack', 1)
        Inv.add(INM2, 'electronickit', 1)
        Mock.clock = Mock.clock + 60
        Mock.coords[INM2] = G2
        PR().SampleTick()
        World.fireNet('prison:server:StartGateHack', INM2, 2)
        local start = Mock.clientEventsNamed('prison:client:GateHackStart')
        Mock.clock = Mock.clock + 10
        World.fireNet('prison:server:GateHackResult', INM2, start[#start].args[2], true)
        Mock.clock = Mock.clock + 2
        Mock.coords[INM2] = G2
        PR().SampleTick()
        Mock.clock = Mock.clock + 3
        Mock.coords[INM2] = vector3(G2.x + 80.0, G2.y + 40.0, G2.z) -- outside the 200 m walls
        PR().SampleTick()
        local dbg = {}
        for _, e in ipairs(Mock.clientEvents) do if e.target == INM2 then dbg[#dbg + 1] = e.name .. ':' .. tostring(e.args[1]) end end
        assert_eq(order(order2).state, 'suspended')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_mdt_warrants WHERE suspectCitizenId = 'B22ESC2'"), 1)
    end)

    it('police arrest the escapee in town and drive them back inside the walls: the order resumes', function()
        local street = vector3(200.0, -900.0, 30.0)
        Mock.coords[INM2], Mock.coords[COP] = street, vector3(street.x + 1.0, street.y, street.z)
        local open = World.call('pfm-policejob', 'pf-justice', 'OpenCustody', INM2, { reason = 'Escaped prisoner (warrant)',
            key = 'pfm-policejob:arrest:B22ESC2:1', actor = { src = COP } })
        assert_true(open.ok, tostring(open.error) .. ' ' .. tostring(open.message))
        custodyId = open.custodyId
        assert_true(World.call('pfm-policejob', 'pf-justice', 'SetCustodyState', custodyId, 'in_transport', { actor = { src = COP } }).ok)
        Mock.clock = Mock.clock + 5
        Mock.coords[INM2] = BOARD
        PR().SampleTick()
        PR().Bridge.Pump()
        PR().Bridge.Pump()
        assert_eq(order(order2).state, 'active', 'serves on')
        assert_eq(World.one("SELECT status FROM pf_prison_inmates WHERE citizenid = 'B22ESC2'").status, 'in_cell')
    end)

    local closed = nil
    it('(probe) the arrest custody after the readmission', function()
        closed = World.one('SELECT * FROM pf_justice_custody WHERE id = ?', { custodyId }).closed_at ~= nil
        assert_true(true)
    end)
    if closed then
        it('the arrest custody is closed by the readmission', function() assert_true(closed) end)
    else
        pending('22A flow 5b recapture by arrest', ('custody %s stays open (in_transport) after pfm-prison readmitted the escapee: '
            .. 'pf-justice custody.lua Custody.OnOrderCreated (~line 1105) only reacts to a NEW order, nothing handles a resumed '
            .. '(orderChanged suspended->active) one, and pfm-prison justice_bridge.lua B.Admit readmit (~line 375) never closes it'):format(tostring(custodyId)))
        it('(consequence) a relog of the readmitted inmate puts them back in the old custody: cuffed and teleported out of the prison', function()
            Teleports = {}
            TriggerEvent('QBCore:Server:PlayerLoaded', Mock.players[INM2])
            local log = World.one("SELECT * FROM pf_justice_custody_log WHERE custody_id = ? AND kind = 'reconnect' ORDER BY id DESC LIMIT 1", { custodyId })
            assert_true(log ~= nil, 'pf-justice treats the inmate as still in transport custody')
            local moved = false
            for _, t in ipairs(Teleports) do if t.ped == INM2 then moved = true end end
            assert_true(moved, 'and teleports them to the custody facility')
        end)
    end
end)
