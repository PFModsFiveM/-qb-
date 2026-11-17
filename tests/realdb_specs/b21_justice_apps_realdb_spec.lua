-- pf-justice apps (batch 21, unit 21F, server/apps.lua) on the real database: every query of the apps and
-- the flows the pages drive, through the app handlers exactly as pf-devices calls them (src, payload):
--   * Court: file a case (server key) -> automatic arraignment on the docket with the defendant's name ->
--     cases list (search by case number and name, scope mine, sort, pages) -> schedule -> plea with a key,
--     a retry is the same decision; warrant reviews by state; court orders issue / list / revoke;
--     the probation caseload (unassigned -> mine after the officer's first appointment);
--   * Community Service: the supervisor board and order list; the citizen access check;
--   * Justice Records: court dates and cases, fines with the citation window, PayOrder on the real ledger
--     under the server's attempt key (a refused attempt, then a new key pays once), the record.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-ambulancejob'] = 'missing', ['pf-services'] = 'missing', ['pfm-prison'] = 'missing', ['pf-government'] = 'missing',
    ['pfm-phone'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' }, judge = { label = 'Judiciary' } }

-- the real ledger
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
for _, soc in ipairs({ 'police', 'doj' }) do
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0", { soc })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', { 'society:' .. soc })
end

Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function() return true end, GetInventory = function() return { items = {} } end, SaveStash = function() end,
    ClearStash = function() end, CanAddItem = function() return true end, ClearInventory = function() end,
    AddItem = function() return true end, RemoveItem = function() return true end, HasItem = function() return true end,
}
Mock.exportsByResource['pfm-policejob'] = { SetCuffed = function() return true end, IsCuffed = function() return false end }
function SetEntityCoords() end
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function() return 1 end, SendMailToJob = function() return 1 end, AddCalendarEvent = function() return 1 end,
}
local approvals = {}
Mock.exportsByResource['pf-policemdt-DEV'] = {
    SetWarrantApproval = function(_, warrantId, decision, opts) approvals[#approvals + 1] = { warrantId = warrantId, decision = decision } return { ok = true } end,
}
Mock.exportsByResource['pf-devices'] = { RegisterApp = function() return true end, RegisterAppHandlers = function() return true end, PushToJob = function() end }

-- pf-justice as its manifest loads it
function GetCurrentResourceName() return 'pf-justice' end
Config = nil
PFPayout = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'shared/cs_tasks.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua',
    'server/clock.lua', 'server/records.lua', 'server/custody.lua', 'server/booking.lua', 'server/property.lua', 'server/bail.lua',
    'server/legacy_import.lua', 'server/compat.lua', 'server/courts.lua', 'server/warrants.lua', 'server/supervision.lua',
    'server/monitors.lua', 'server/community_service.lua', 'server/restitution.lua', 'server/api.lua', 'server/apps.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local A = J.Apps

local JUDGE, CLERK, PROS, PO, CIV, CIV2, SGT, COP = 1, 2, 3, 4, 5, 6, 7, 8
local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function one(sql, p) return MySQL.single.await(sql, p or {}) end
local function job(src, cid, name, grade, onduty, jtype)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.job = { name = name, type = jtype, grade = { level = grade }, onduty = onduty ~= false }
    return P
end
local function rpc(app, method, src, payload)
    for _, entry in ipairs(A.Defs) do
        if entry.def.id == app then return entry.handlers[method](src, payload or {}, { app = app, method = method }) end
    end
    error('no app ' .. app)
end
local function key(src, scope) return rpc(scope == 'ia' and 'justice-records' or 'court', 'key', src, { scope = scope }).key end
local function person(cid, first, last)
    MySQL.insert.await([[INSERT INTO players (citizenid, license, name, money, charinfo, job, position, metadata)
        VALUES (?, 'license:x', ?, '{}', ?, '{}', '{}', '{}')]], { cid, first, json.encode({ firstname = first, lastname = last }) })
end

Mock.clock = 1800000000
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 10
    approvals = {}
    J.Rate.Forget('')
    job(JUDGE, 'JUDGECID', 'judge', 1, true)
    job(CLERK, 'CLERKCID', 'doj', 0, true, 'doj')
    job(PROS, 'PROSCID', 'doj', 1, true, 'doj')
    job(PO, 'POCID', 'doj', 3, true, 'doj')
    job(SGT, 'SGTCID', 'police', 4, true, 'leo')
    job(COP, 'COPCID', 'police', 2, true, 'leo')
    Mock.newPlayer(CIV, 'CIVCID').PlayerData.money = { cash = 50, bank = 1000 }
    Mock.newPlayer(CIV2, 'CIV2CID')
end

assert(J.Boot(), 'pf-justice boot')
assert(J.Schema.Has(5), 'schema v3-v5')
person('CIVCID', 'Rosa', 'Delgado')
person('CIV2CID', 'Tom', 'Baker')

local caseId, caseNo

describe('Court app on the real database', function()
    it('a prosecutor files a case; the docket shows its arraignment with the defendant\'s name', function()
        local k = key(PROS, 'file')
        local res = rpc('court', 'file', PROS, { cid = 'CIVCID', kind = 'criminal', title = 'Shop theft', charges = { { code = 'PC-484', label = 'Petty theft' } }, key = k })
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        caseId, caseNo = res.caseId, res.caseNo
        local again = rpc('court', 'file', PROS, { cid = 'CIVCID', kind = 'criminal', charges = { { code = 'PC-484', label = 'Petty theft' } }, key = k })
        assert_true(again.ok and again.duplicate and again.caseId == caseId, 'a retry with the same key is the same case')
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_cases WHERE citizenid = ?', { 'CIVCID' }), 1)
        assert_eq(one('SELECT prosecutor_cid FROM pf_justice_cases WHERE id = ?', { caseId }).prosecutor_cid, 'PROSCID')
        local docket = rpc('court', 'docket', CLERK, {})
        assert_true(docket.ok, tostring(docket.error))
        local found
        for _, h in ipairs(docket.list) do if h.caseId == caseId then found = h end end
        assert_true(found ~= nil and found.kind == 'arraignment' and found.name == 'Rosa Delgado' and found.cid == 'CIVCID')
        assert_eq(found.courtroomLabel, 'Courtroom 1')
    end)

    it('the case list searches by case number and name, filters mine, sorts and pages on the server', function()
        local byNo = rpc('court', 'cases', JUDGE, { q = caseNo:sub(1, 6) })
        assert_true(byNo.ok, tostring(byNo.error))
        assert_eq(byNo.list[1].id, caseId)
        local byName = rpc('court', 'cases', JUDGE, { q = 'delga' })
        assert_true(#byName.list == 1 and byName.list[1].name == 'Rosa Delgado')
        assert_eq(#rpc('court', 'cases', JUDGE, { q = 'nobody here' }).list, 0)
        assert_eq(#rpc('court', 'cases', PROS, { scope = 'mine' }).list, 1)
        assert_eq(#rpc('court', 'cases', CLERK, { scope = 'mine' }).list, 0)
        assert_eq(#rpc('court', 'cases', JUDGE, { scope = 'closed' }).list, 0)
        -- 26 more cases: two pages
        for i = 1, 26 do
            MySQL.insert.await([[INSERT INTO pf_justice_cases (case_no, citizenid, state, kind, charges, filed_by, filed_at)
                VALUES (?, 'CIV2CID', 'filed', 'violation', '[]', 'system', ?)]], { ('VI26-9%04d'):format(i), Mock.clock + i })
        end
        local p1 = rpc('court', 'cases', JUDGE, { kind = 'violation', sort = 'filed_desc' })
        assert_true(p1.ok and #p1.list == 25 and p1.more)
        assert_eq(p1.list[1].caseNo, 'VI26-90026', 'newest first')
        local p2 = rpc('court', 'cases', JUDGE, { kind = 'violation', sort = 'filed_desc', page = 2 })
        assert_true(#p2.list == 1 and not p2.more)
        assert_eq(rpc('court', 'cases', JUDGE, { kind = 'violation', sort = 'case_no' }).list[1].caseNo, 'VI26-90001')
        assert_eq(rpc('court', 'cases', JUDGE, { kind = 'violation' }).list[1].name, 'Tom Baker')
    end)

    it('schedule and decide through the app with server keys; a retry records nothing twice', function()
        local c = rpc('court', 'case', CLERK, { id = caseId })
        assert_true(c.ok and c.case.name == 'Rosa Delgado' and c.can.schedule and not c.can.decide)
        assert_true(rpc('court', 'case', JUDGE, { id = caseId }).can.decide)
        local hk = key(CLERK, 'hearing')
        local s = rpc('court', 'schedule', CLERK, { caseId = caseId, kind = 'arraignment', at = Mock.clock + 1800, courtroom = 'courtroom_2', key = hk })
        assert_true(s.ok, tostring(s.error) .. ' ' .. tostring(s.message))
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_hearings WHERE case_id = ? AND state = 'scheduled'", { caseId }), 1, 'rescheduled, not doubled')
        local dk = key(JUDGE, 'decision')
        local d = rpc('court', 'decide', JUDGE, { caseId = caseId, key = dk, decision = { kind = 'plea', plea = 'not_guilty', note = 'counsel present' } })
        assert_true(d.ok, tostring(d.error) .. ' ' .. tostring(d.message))
        local again = rpc('court', 'decide', JUDGE, { caseId = caseId, key = dk, decision = { kind = 'plea', plea = 'not_guilty' } })
        assert_true(again.ok and again.duplicate)
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_decisions WHERE case_id = ?', { caseId }), 1)
        assert_eq(one('SELECT state FROM pf_justice_cases WHERE id = ?', { caseId }).state, 'plea_not_guilty')
        assert_eq(one('SELECT idem_key FROM pf_justice_decisions WHERE case_id = ?', { caseId }).idem_key, dk)
        -- a prosecutor may not enter a verdict, whatever the page sends
        local pk = key(PROS, 'decision')
        assert_eq(rpc('court', 'decide', PROS, { caseId = caseId, key = pk, decision = { kind = 'verdict', verdict = 'guilty' } }).error, 'no_permission')
    end)

    it('warrant reviews by state; the judge decides through the app and the MDT is told', function()
        local r = J.Warrants.Request({ warrantId = 'W77', type = 'arrest', targetCid = 'CIVCID', affidavit = 'Seen on camera', requestedBy = 'COPCID' }, { key = 'test:w77' }, {})
        assert_true(r.ok)
        local list = rpc('court', 'warrants', JUDGE, { state = 'requested' })
        assert_true(list.ok and #list.list == 1 and list.list[1].targetName == 'Rosa Delgado' and list.list[1].canDecide)
        local res = rpc('court', 'decideWarrant', JUDGE, { reviewId = r.reviewId, decision = 'approve' })
        assert_true(res.ok and res.state == 'approved' and res.notified)
        assert_true(approvals[1].warrantId == 'W77' and approvals[1].decision == 'approve')
        assert_eq(#rpc('court', 'warrants', JUDGE, { state = 'requested' }).list, 0)
        assert_eq(rpc('court', 'warrants', JUDGE, { state = 'approved' }).list[1].id, r.reviewId)
    end)

    it('court orders: issue, list the valid ones, revoke', function()
        local k = key(JUDGE, 'courtorder')
        local res = rpc('court', 'issueOrder', JUDGE, { kind = 'search', cid = 'CIVCID', caseId = caseId, hours = 24, note = 'garage', key = k })
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        local list = rpc('court', 'courtOrders', CLERK, { scope = 'active' })
        assert_true(list.ok and list.list[1].ref == res.ref and list.list[1].name == 'Rosa Delgado' and list.list[1].note == 'garage')
        assert_true(J.Courts.IsCourtOrderValid(res.ref, 'search', 'CIVCID'))
        assert_true(rpc('court', 'revokeOrder', JUDGE, { ref = res.ref, reason = 'served' }).ok)
        assert_false(J.Courts.IsCourtOrderValid(res.ref, 'search', 'CIVCID'))
        assert_eq(#rpc('court', 'courtOrders', CLERK, { scope = 'active' }).list, 0)
        assert_true(rpc('court', 'courtOrders', CLERK, { scope = 'all' }).list[1].revokedAt ~= nil)
    end)

    it('the probation caseload: unassigned until the officer acts, then on their list', function()
        local o = J.API.CreateOrder({ cid = 'CIV2CID', kind = 'probation', days = 30, conditions = { { kind = 'checkin', everyDays = 7 } },
            sourceRef = { type = 'court_decision', id = 'b21' } }, { key = 'test:b21:probation' })
        assert_true(o.ok)
        J.Supervision.Ensure(J.Orders.Public(J.Orders.Row(o.orderId)))
        local un = rpc('court', 'caseload', PO, { scope = 'unassigned' })
        assert_true(un.ok and #un.list == 1 and un.list[1].name == 'Tom Baker' and un.list[1].nextCheckinAt ~= nil)
        assert_eq(#rpc('court', 'caseload', PO, { scope = 'mine' }).list, 0)
        local k = key(PO, 'appointment')
        local a = rpc('court', 'appointment', PO, { supId = un.list[1].id, at = Mock.clock + 3600, office = 1, minutes = 30, key = k })
        assert_true(a.ok, tostring(a.error) .. ' ' .. tostring(a.message))
        assert_eq(#rpc('court', 'caseload', PO, { scope = 'mine' }).list, 1)
        local sup = rpc('court', 'supervision', PO, { cid = 'CIV2CID' })
        assert_true(sup.ok and #sup.supervision.appointments == 1 and sup.name == 'Tom Baker')
    end)
end)

describe('Community Service app on the real database', function()
    it('the supervisor board and order list; a citizen with an open order may open the app', function()
        local o = J.API.CreateOrder({ cid = 'CIVCID', kind = 'community_service', units = 5, sourceRef = { type = 'court_decision', id = 'b21cs' } }, { key = 'test:b21:cs' })
        assert_true(o.ok)
        assert_true(A.CsAccess(CIV))
        assert_false(A.CsAccess(CIV2))
        MySQL.insert.await('INSERT INTO pf_justice_cs_shifts (order_id, citizenid, site, started_at) VALUES (?, ?, ?, ?)', { o.orderId, 'CIVCID', 'cityhall', Mock.clock })
        local P = Mock.players[PO]
        P.PlayerData.job.onduty = true
        local stubbed = J.CS.IsSupervisor
        J.CS.IsSupervisor = function(src) return src == PO end -- the GOV qualification (pf-government is not loaded here)
        local board = rpc('community-service', 'board', PO, {})
        assert_true(board.ok, tostring(board.error))
        assert_true(#board.list == 1 and board.list[1].name == 'Rosa Delgado' and board.list[1].units == 5 and board.list[1].task == nil)
        local orders = rpc('community-service', 'orders', PO, { scope = 'open' })
        assert_true(orders.ok and #orders.list == 1 and orders.list[1].id == o.orderId)
        assert_eq(#rpc('community-service', 'orders', PO, { scope = 'completed' }).list, 0)
        J.CS.IsSupervisor = stubbed
        assert_eq(rpc('community-service', 'board', CIV, {}).error, 'no_permission')
    end)
end)

describe('Justice Records portal on the real database', function()
    it('court dates and cases of the caller only', function()
        local t = rpc('court', 'schedule', CLERK, { caseId = caseId, kind = 'trial', at = Mock.clock + 7200, courtroom = 'courtroom_2', key = key(CLERK, 'hearing') })
        assert_true(t.ok, tostring(t.error) .. ' ' .. tostring(t.message))
        local res = rpc('justice-records', 'court', CIV, {})
        assert_true(res.ok)
        assert_true(#res.hearings == 1 and res.hearings[1].caseNo == caseNo and res.hearings[1].kind == 'trial' and res.hearings[1].courtroom == 'Courtroom 2')
        assert_eq(res.hearings[1].notes, nil)
        assert_eq(#res.cases, 1)
        assert_eq(#rpc('justice-records', 'court', CIV2, {}).cases, 26)
    end)

    it('fines: a refused payment counts nothing; the next press is a new attempt key and pays society:doj once', function()
        local f = J.API.CreateOrder({ cid = 'CIVCID', kind = 'fine', amount = 1500, sourceRef = { type = 'court_decision', id = 'b21fine' } }, { key = 'test:b21:fine' })
        assert_true(f.ok)
        local list = rpc('justice-records', 'fines', CIV, {})
        assert_true(list.ok and list.list[1].id == f.orderId and list.list[1].payable and list.list[1].owed == 1500)
        local before = n("SELECT account_balance FROM bank_accounts WHERE account_name = 'doj'")
        local refused = rpc('justice-records', 'pay', CIV, { orderId = f.orderId, account = 'bank' })
        assert_eq(refused.error, 'insufficient_funds')
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_order_events WHERE idem_key = ?', { 'pf-justice:portal:' .. f.orderId .. ':pay:1' }), 1)
        assert_eq(one('SELECT state FROM pf_justice_orders WHERE id = ?', { f.orderId }).state, 'issued')
        Mock.players[CIV].PlayerData.money.bank = 2000
        J.Rate.Forget('')
        local paid = rpc('justice-records', 'pay', CIV, { orderId = f.orderId, account = 'bank' })
        assert_true(paid.ok, tostring(paid.error))
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_order_events WHERE idem_key = ?', { 'pf-justice:portal:' .. f.orderId .. ':pay:2' }), 1)
        assert_eq(n("SELECT account_balance FROM bank_accounts WHERE account_name = 'doj'"), before + 1500)
        J.Rate.Forget('')
        local again = rpc('justice-records', 'pay', CIV, { orderId = f.orderId, account = 'bank' })
        assert_true(again.ok and again.duplicate)
        assert_eq(n("SELECT account_balance FROM bank_accounts WHERE account_name = 'doj'"), before + 1500, 'paid once')
        assert_eq(rpc('justice-records', 'pay', CIV2, { orderId = f.orderId }).error, 'not_found', 'not their order')
        -- the conviction entry of the paid fine is on the caller's record
        local rec = rpc('justice-records', 'record', CIV, {})
        assert_true(rec.ok and #rec.entries >= 1 and rec.entries[1].kind == 'conviction')
    end)

    it('a citation inside its window can be contested once from the portal', function()
        Mock.invokingResource = 'pfm-policejob'
        local c = exports['pf-justice']:IssueCitation({ cid = 'CIV2CID', violation = 'speeding', amount = 200, plate = 'AB12', officerCid = 'COPCID' },
            { key = 'test:b21:cit', actor = { src = COP } })
        Mock.invokingResource = nil
        assert_true(c.ok, tostring(c.error) .. ' ' .. tostring(c.message))
        local fines = rpc('justice-records', 'fines', CIV2, {})
        local row
        for _, o in ipairs(fines.list) do if o.id == c.orderId then row = o end end
        assert_true(row ~= nil and row.contestable and row.violation == 'speeding' and row.plate == 'AB12')
        assert_true(rpc('justice-records', 'contest', CIV2, { orderId = c.orderId, reason = 'radar was off' }).ok)
        assert_eq(one('SELECT state FROM pf_justice_orders WHERE id = ?', { c.orderId }).state, 'contested')
        assert_eq(rpc('justice-records', 'contest', CIV, { orderId = c.orderId }).error, 'no_permission', 'only the cited citizen')
    end)
end)
