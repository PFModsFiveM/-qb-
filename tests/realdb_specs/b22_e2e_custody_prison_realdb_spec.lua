-- 22A end to end on MariaDB: arrest -> booking -> property -> bail OR court -> prison -> work credit ->
-- release -> property back -> trust payout, with the REAL pf-justice (every server file), the REAL
-- pfm-prison (main, bridge, facility, schedule, discipline, visitation, work, economy, security,
-- supplies, apps) and the REAL pfm-banking ledger in one world (tests/specs/b22_e2e_world.lua).
-- pfm-policejob / pf-policemdt-DEV are the callers: their calls are made with their resource name and
-- the exact shapes their code uses. Restarts of pf-justice and pfm-prison happen in the middle of
-- each path and must not double money, items or lose state.
-- Stubbed: FiveM natives, inventory (in memory, real semantics), pf-citizen mail, pf-devices registry,
-- pfm-policejob cuffs, pfm-doorlock, pfm-minigames, pf-services.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('tests/specs/b22_e2e_world.lua')
function IsDuplicityVersion() return true end
function SetEntityCoords() end
Mock.clock = 1800000000
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' }, judge = { label = 'Judiciary' },
    corrections = { label = 'Corrections', grades = {} }, mechanic = { label = 'Mechanic' } }
World.installResourceState({ ['pf-ambulancejob'] = 'missing', ['pf-government'] = 'missing', ['pf-policemdt-DEV'] = 'missing',
    ['pfm-phone'] = 'missing' })

World.startBank()
local Inv = World.inventory()
local mails = {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, opts) mails[#mails + 1] = { cid = cid, opts = opts } return #mails end,
    AddCalendarEvent = function() return 1 end,
}
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
local cuffs = {}
Mock.exportsByResource['pfm-policejob'] = {
    SetCuffed = function(_, src, on) cuffs[src] = on return true end,
    IsCuffed = function(_, src) return cuffs[src] == true end,
    RegisterReferenceSample = function() return { ok = true } end,
}
Mock.exportsByResource['pfm-doorlock'] = { SetDoorState = function(_, id, locked) return { ok = true, locked = locked, changed = true } end }
Mock.exportsByResource['pfm-minigames'] = { IssueChallenge = function() return nil end, Verify = function() return false end, Cancel = function() end }
Mock.exportsByResource['pf-services'] = { Emit = function() return 1 end }

-- pf-justice as its fxmanifest loads it
local JFILES = { '[pfscripts]/pf-justice/config.lua', '[pfscripts]/pf-justice/shared/states.lua', '[pfscripts]/pf-justice/shared/cs_tasks.lua',
    '@pfm-banking/payouts.lua' }
for _, f in ipairs({ 'main', 'schema', 'orders', 'clock', 'records', 'custody', 'booking', 'property', 'bail', 'legacy_import', 'compat',
    'courts', 'warrants', 'supervision', 'monitors', 'community_service', 'restitution', 'api', 'apps' }) do
    JFILES[#JFILES + 1] = '[pfscripts]/pf-justice/server/' .. f .. '.lua'
end
World.start('pf-justice', JFILES, { boot = function(env)
    assert(env.PFJustice.Boot(), 'pf-justice boot')
    env.PFJustice.Custody.LoadOnline() -- its start thread
    Mock.eventHandlers['onResourceStart']('pf-justice')
end })
local function J() return World.env('pf-justice').PFJustice end

-- pfm-prison as its fxmanifest loads it (locales: the shared Lang mock)
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

-- the corrections budget pays the wages
assert(World.call(nil, 'pfm-banking', 'AddMoney', 'corrections', 20000, 'b22 budget', 'b22:fund:corrections'), 'corrections funded')

local COP, SUS, JUDGE, CLERK, PAYER, INM = 1, 2, 3, 4, 5, 6
local STREET = vector3(300.0, -600.0, 29.0)
local DESK = vector3(441.0, -981.0, 30.7)        -- Mission Row booking zone and front (bail) desk
local CW = World.env('pfm-prison').Config.Work
local BOARD = CW.Board

local function person(src, cid, items)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.money = { cash = 0, bank = 3000 }
    P.PlayerData.job = { name = 'mechanic', type = 'none', grade = { level = 1 }, onduty = true }
    P.PlayerData.metadata.injail = 0
    P.SetJobDuty = function(on) P.PlayerData.job.onduty = on end
    P.Functions.SetJobDuty = P.SetJobDuty
    for _, it in ipairs(items or {}) do Inv.add(src, it[1], it[2]) end
    return P
end
local function job(src, cid, name, grade, jtype)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.job = { name = name, type = jtype, grade = { level = grade }, onduty = true }
    return P
end
job(COP, 'B22COP', 'police', 2, 'leo')
job(JUDGE, 'B22JUDGE', 'judge', 1)
job(CLERK, 'B22CLERK', 'doj', 0, 'doj')
person(PAYER, 'B22MOM')
person(SUS, 'B22BAIL', { { 'lockpick', 1 }, { 'goldbar', 2 }, { 'phone', 1 } })
person(INM, 'B22INM', { { 'lockpick', 1 }, { 'goldbar', 3 }, { 'phone', 1 } })
for _, src in ipairs({ COP, JUDGE, CLERK, PAYER, SUS, INM }) do TriggerEvent('QBCore:Server:PlayerLoaded', Mock.players[src]) end

local function pj(fn, ...) return World.call('pfm-policejob', 'pf-justice', fn, ...) end
local function mdt(fn, ...) return World.call('pf-policemdt-DEV', 'pf-justice', fn, ...) end
local function courtKey(src, scope) return app('court', 'key', src, { scope = scope }).key end
local function custody(id) return World.one('SELECT * FROM pf_justice_custody WHERE id = ?', { id }) end
local function order(id) return World.one('SELECT * FROM pf_justice_orders WHERE id = ?', { id }) end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function stashTotal(prefix)
    local n = 0
    for id, items in pairs(Inv.stashes) do
        if id:sub(1, #prefix) == prefix then for _, it in ipairs(items) do n = n + (it.amount or 0) end end
    end
    return n
end

-- arrest in the street, transport, booking at Mission Row (property seized with the booking)
local function arrestAndBook(src, cid, n)
    Mock.coords[COP], Mock.coords[src] = STREET, vector3(STREET.x + 1.0, STREET.y, STREET.z)
    local open = pj('OpenCustody', src, { reason = 'Armed robbery', charges = { { code = 'PC-211', label = 'Robbery' } },
        key = ('pfm-policejob:arrest:%s:%d'):format(cid, n), actor = { src = COP } })
    assert_true(open.ok, 'arrest: ' .. tostring(open.error) .. ' ' .. tostring(open.message))
    local id = open.custodyId
    assert_true(pj('SetCustodyState', id, 'in_transport', { actor = { src = COP } }).ok, 'transport')
    Mock.coords[COP], Mock.coords[src] = DESK, vector3(DESK.x + 1.0, DESK.y, DESK.z)
    local b = pj('SetCustodyState', id, 'booking', { actor = { src = COP } })
    assert_true(b.ok, 'booking state: ' .. tostring(b.error))
    local bk = pj('BookCustody', id, { seize = true, height = 182, marks = 'tattoo left arm' }, { actor = { src = COP } })
    assert_true(bk.ok, 'book: ' .. tostring(bk.error) .. ' ' .. tostring(bk.message))
    return id, bk
end

describe('22A flow 2a: arrest -> booking -> property -> bail -> release -> property back', function()
    local custodyId, receiptId, bailId
    it('arrest, booking and the property locker (the pockets are empty, the locker holds everything once)', function()
        local bk
        custodyId, bk = arrestAndBook(SUS, 'B22BAIL', 1)
        receiptId = bk.receiptId
        assert_true(bk.bookingNo:match('^BK%-') ~= nil, tostring(bk.bookingNo))
        assert_true(receiptId ~= nil, 'property receipt')
        assert_eq(Inv.total(SUS), 0, 'pockets emptied into the locker')
        assert_eq(stashTotal('pf_justice_property_'), 4)
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_justice_property_items WHERE property_id = ?', { receiptId }), 3)
        -- the same booking again (a retry): nothing new
        local again = pj('BookCustody', custodyId, { seize = true }, { actor = { src = COP } })
        assert_true(again.ok and again.duplicate)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_bookings WHERE custody_id = ?", { custodyId }), 1)
        local cell = pj('AssignHoldingCell', custodyId, 'mrpd_cell_1', { actor = { src = COP } })
        assert_true(cell.ok, 'cell: ' .. tostring(cell.error) .. ' ' .. tostring(cell.message))
        assert_eq(custody(custodyId).state, 'held')
    end)

    it('the officer offers bail (MDT); pf-justice restarts before anyone pays', function()
        local o = mdt('OfferBail', { custodyId = custodyId }, { amount = 1500 }, { actor = { src = COP } })
        assert_true(o.ok, tostring(o.error) .. ' ' .. tostring(o.message))
        bailId = o.bailId
        World.restart('pf-justice')
        assert_eq(custody(custodyId).state, 'held')
        assert_eq(World.one('SELECT state FROM pf_justice_bail WHERE id = ?', { bailId }).state, 'offered')
    end)

    it('the family pays at the front desk: one keyed transfer to society:doj, release, property back once', function()
        local doj = World.society('doj')
        Mock.coords[PAYER] = DESK
        Mock.coords[SUS] = Config and DESK or DESK
        local res = mdt('AcceptBail', bailId, PAYER, {})
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        assert_eq(res.state, 'posted')
        assert_eq(bank(PAYER), 3000 - 1500)
        assert_eq(World.society('doj'), doj + 1500)
        local c = custody(custodyId)
        assert_true(c.closed_at ~= nil, 'custody closed')
        assert_eq(c.release_reason, 'bailed')
        assert_eq(Inv.count(SUS, 'lockpick'), 1)
        assert_eq(Inv.count(SUS, 'goldbar'), 2)
        assert_eq(Inv.count(SUS, 'phone'), 1)
        assert_eq(stashTotal('pf_justice_property_'), 0)
        -- a second press, a restart, a relog: no second charge, no second set of items
        Mock.clock = Mock.clock + 10
        local again = mdt('AcceptBail', bailId, PAYER, {})
        assert_true(again.ok and again.duplicate)
        World.restart('pf-justice')
        TriggerEvent('QBCore:Server:PlayerLoaded', Mock.players[SUS])
        assert_eq(bank(PAYER), 1500)
        assert_eq(World.society('doj'), doj + 1500)
        assert_eq(#World.txLike('pf-justice:bail:' .. bailId .. ':%'), 1)
        assert_eq(Inv.count(SUS, 'goldbar'), 2)
        assert_eq(World.one('SELECT state FROM pf_justice_property WHERE id = ?', { receiptId }).state, 'returned')
    end)
end)

describe('22A flow 2b: arrest -> booking -> court -> prison -> work credit -> release -> property back -> trust payout', function()
    local custodyId, receiptId, caseId, prisonOrder, fineOrder
    it('arrest and booking; pf-justice restarts with the citizen held', function()
        local bk
        custodyId, bk = arrestAndBook(INM, 'B22INM', 1)
        receiptId = bk.receiptId
        assert_eq(Inv.total(INM), 0)
        assert_true(pj('AssignHoldingCell', custodyId, 'mrpd_cell_2', { actor = { src = COP } }).ok)
        World.restart('pf-justice')
        local g = pj('GetCustody', 'B22INM')
        assert_true(g.ok and g.custody ~= nil, 'the open custody survives the restart')
        assert_eq(g.custody.state, 'held')
    end)

    it('the MDT files the case (FileCase, keyed); a judge takes a guilty plea and sentences prison + fine', function()
        local spec = { cid = 'B22INM', charges = { { code = 'PC-211', name = 'Robbery' } }, custodyId = custodyId, incidentIds = { '77' },
            evidenceIds = {}, mdtCaseId = 501, mdtCaseNo = 'C-501', title = 'Store robbery', filedBy = 'B22COP' }
        local f = mdt('FileCase', spec, { key = 'pf-policemdt:case:501:court:1', actor = { kind = 'system', label = 'pf-policemdt case submission' }, filedBy = 'B22COP' })
        assert_true(f.ok, tostring(f.error) .. ' ' .. tostring(f.message))
        caseId = f.caseId
        assert_true(mdt('FileCase', spec, { key = 'pf-policemdt:case:501:court:1', actor = { kind = 'system', label = 'x' } }).duplicate)
        local plea = app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = caseId, decision = { kind = 'plea', plea = 'guilty' } })
        assert_true(plea.ok, tostring(plea.error) .. ' ' .. tostring(plea.message))
        local key = courtKey(JUDGE, 'decision')
        local s = app('court', 'decide', JUDGE, { key = key, caseId = caseId,
            decision = { kind = 'sentence', orders = { { kind = 'prison', minutes = 20 }, { kind = 'fine', amount = 500 } } } })
        assert_true(s.ok, tostring(s.error) .. ' ' .. tostring(s.message))
        prisonOrder, fineOrder = s.orders[1], s.orders[2]
        assert_eq(order(prisonOrder).facility, 'bolingbroke')
        assert_eq(order(prisonOrder).state, 'active')
        assert_eq(order(fineOrder).state, 'issued')
        -- the custody hands over to the order; its property now waits for that order
        local c = custody(custodyId)
        assert_true(c.closed_at ~= nil)
        assert_eq(c.release_reason, 'transferred')
        assert_eq(tonumber(World.one('SELECT order_id FROM pf_justice_property WHERE id = ?', { receiptId }).order_id), prisonOrder)
    end)

    local jailMoneyKey
    it('prison intake: one inmate row, off duty with the job kept, jail money once; a pfm-prison restart repeats nothing', function()
        Mock.coords[INM] = BOARD
        PR().Bridge.Pump()
        local row = World.one('SELECT * FROM pf_prison_inmates WHERE citizenid = ?', { 'B22INM' })
        assert_true(row ~= nil, 'admitted')
        assert_eq(tonumber(row.order_id), prisonOrder)
        assert_eq(row.status, 'in_cell')
        assert_eq(Mock.players[INM].PlayerData.job.name, 'mechanic')
        assert_false(Mock.players[INM].PlayerData.job.onduty, 'off duty while serving (D1)')
        jailMoneyKey = ('pfm-prison:jailmoney:%s:%d'):format('B22INM', prisonOrder)
        assert_eq(World.tx(jailMoneyKey).state, 'completed')
        local cash = Mock.players[INM].PlayerData.money.cash
        World.restart('pfm-prison')
        PR().Bridge.Pump()
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_prison_inmates WHERE citizenid = ?', { 'B22INM' }), 1)
        assert_eq(Mock.players[INM].PlayerData.money.cash, cash, 'no second jail money')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_prison_events WHERE citizenid = 'B22INM' AND kind = 'intake'"), 1)
        assert_true(World.call('pf-justice', 'pfm-prison', 'IsInside', INM), 'the clock sees the inmate inside')
    end)

    it('the clock counts online time inside; a pf-justice restart keeps what was served', function()
        for _ = 1, 20 do Mock.clock = Mock.clock + 15 J().Clock.Tick(os.time()) end
        local served = tonumber(order(prisonOrder).served_seconds)
        assert_true(served >= 280, 'served ' .. tostring(served))
        World.restart('pf-justice')
        assert_eq(tonumber(order(prisonOrder).served_seconds), served)
        Mock.clock = Mock.clock + 15
        J().Clock.Tick(os.time())
        assert_true(tonumber(order(prisonOrder).served_seconds) > served, 'counting again after the restart')
    end)

    local ticketWage
    it('a kitchen shift: one work-log ticket, a keyed pf-justice credit, a wage from corrections into the trust', function()
        local corrections = World.society('corrections')
        Mock.clock = Mock.clock + 30
        World.fireNet('pfm-prison:server:WorkStart', INM, 'kitchen')
        assert_true(PR().Work.sessions[INM] ~= nil, 'shift started at the board')
        for i, st in ipairs(CW.Jobs.kitchen.steps) do
            Mock.clock = Mock.clock + st.minSeconds + 5
            Mock.coords[INM] = st.coords
            World.fireNet('pfm-prison:server:WorkStep', INM, i)
            assert_eq(PR().Work.sessions[INM].step, i, 'step ' .. i)
        end
        Mock.clock = Mock.clock + 30
        -- pfm-prison restarts mid-shift: the shift in memory is gone (no credit for half a shift)
        World.fireNet('pfm-prison:server:WorkFinish', INM)
        local log = World.one('SELECT * FROM pf_prison_work_log WHERE order_id = ? AND ticket = 1', { prisonOrder })
        assert_true(log ~= nil, 'ticket 1 written')
        assert_eq(tonumber(log.credit_seconds), CW.Jobs.kitchen.creditSeconds, 'pf-justice applied the credit')
        assert_eq(tonumber(order(prisonOrder).credit_seconds), CW.Jobs.kitchen.creditSeconds)
        local credit = World.one('SELECT * FROM pf_justice_order_events WHERE order_id = ? AND idem_key = ?',
            { prisonOrder, ('pfm-prison:credit:%d:1'):format(prisonOrder) })
        assert_true(credit ~= nil, 'the credit carries the pfm-prison key')
        ticketWage = CW.Jobs.kitchen.wage
        assert_eq(World.society('corrections'), corrections - ticketWage)
        assert_eq(PR().Economy.Balance('B22INM').available, ticketWage)
        -- the credit retried with the same key (as the work tick does after a lost answer) is not applied twice
        PR().Work.Credit('B22INM', prisonOrder, 1, CW.Jobs.kitchen.creditSeconds)
        assert_eq(tonumber(order(prisonOrder).credit_seconds), CW.Jobs.kitchen.creditSeconds)
        assert_true(PR().Economy.Reconcile().ok, 'trust reconciles with the ledger')
    end)

    it('both resources restart; the sentence runs out; release once; the booking locker comes back once', function()
        World.restart('pfm-prison')
        World.restart('pf-justice')
        Mock.coords[INM] = BOARD
        PR().Bridge.Pump()
        local n = 0
        while order(prisonOrder).state == 'active' and n < 200 do
            Mock.clock = Mock.clock + 15
            J().Clock.Tick(os.time())
            n = n + 1
        end
        assert_eq(order(prisonOrder).state, 'completed')
        PR().Bridge.Pump()
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_prison_inmates WHERE citizenid = ?', { 'B22INM' }), 0, 'let out')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_prison_events WHERE citizenid = 'B22INM' AND kind = 'release'"), 1)
        assert_eq(Inv.count(INM, 'lockpick'), 1)
        assert_eq(Inv.count(INM, 'goldbar'), 3)
        assert_eq(Inv.count(INM, 'phone'), 1)
        assert_eq(World.one('SELECT state FROM pf_justice_property WHERE id = ?', { receiptId }).state, 'returned')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'B22INM' AND kind = 'conviction'"), 1)
        -- a relog and restarts afterwards hand nothing back twice
        World.restart('pf-justice')
        World.restart('pfm-prison')
        TriggerEvent('QBCore:Server:PlayerLoaded', Mock.players[INM])
        Mock.clock = Mock.clock + 10
        PR().Bridge.Pump()
        assert_eq(Inv.count(INM, 'goldbar'), 3)
        assert_eq(Inv.count(INM, 'lockpick'), 1)
    end)

    it('the trust pays out to the bank once (a restart in between pays nothing more)', function()
        local before = bank(INM)
        PR().Economy.Tick(os.time())
        assert_eq(bank(INM), before + ticketWage)
        assert_eq(PR().Economy.Balance('B22INM').available, 0)
        World.restart('pfm-prison')
        Mock.clock = Mock.clock + 600
        PR().Economy.Tick(os.time())
        assert_eq(bank(INM), before + ticketWage, 'paid once')
        assert_eq(#World.txLike('pfm-prison:trust:B22INM:r%'), 1)
        assert_true(PR().Economy.Reconcile().ok)
    end)

    it('the court fine is paid once from Justice Records to society:doj', function()
        local doj = World.society('doj')
        local before = bank(INM)
        local p = app('justice-records', 'pay', INM, { orderId = fineOrder, account = 'bank' })
        assert_true(p.ok, tostring(p.error) .. ' ' .. tostring(p.message))
        Mock.clock = Mock.clock + 10
        assert_true(app('justice-records', 'pay', INM, { orderId = fineOrder, account = 'bank' }).duplicate)
        assert_eq(bank(INM), before - 500)
        assert_eq(World.society('doj'), doj + 500)
        assert_eq(order(fineOrder).state, 'paid')
    end)
end)
