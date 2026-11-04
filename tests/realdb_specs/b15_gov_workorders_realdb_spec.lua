-- Batch 15 unit 15E, pf-government municipal work orders on a real database with the real ledger:
--   1. migrations v5/v6 apply on a fresh database and a second run applies nothing;
--   2. the generator makes orders from district thresholds (one per rule, capped per district) and
--      city events make one order each (the event id is the key);
--   3. a claim is one unit with a TTL; a unit counts only with the claimant in person, on foot,
--      inside the site radius for the kind's minimum time (server positions, sampled);
--   4. every unit changes the saved district row, and the next simulation tick keeps the repair;
--   5. paid orders pay each staff/job worker once (pf-government:wo:<id>:pay:<cid>:<n>) from the
--      department's society; community service pays nothing; a refused payout retries under the
--      next numbered key; claims and orders expire.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-services'] = 'missing', ['pfm-houses'] = 'missing', ['pfm-phone'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}

local T = os.time()
local realTime = os.time
os.time = function(t) if t then return realTime(t) end return T end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government', grades = {} } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/budgets.lua',
    'server/bills.lua', 'server/audit.lua', 'server/infrastructure.lua', 'server/workorders.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function DebugPrint() end
local govX = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-government'] = govX
Mock.exportsByResource['__self'] = nil

local function num(v) return tonumber(v) or 0 end
local function scalar(q, p) return MySQL.scalar.await(q, p or {}) end
local function district(name) return MySQL.single.await('SELECT * FROM pf_gov_infra_district_state WHERE district_name = ?', { name }) end
local function setDistrict(name, fields)
    for k, v in pairs(fields) do
        MySQL.update.await(('UPDATE pf_gov_infra_district_state SET `%s` = ? WHERE district_name = ?'):format(k), { v, name })
    end
end
local function society(name) return num(scalar('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) end
local function fund(name, amount, key) assert_true((exports['pfm-banking']:AddMoney(name, amount, 'test funding', key)), 'funded ' .. name) end
local completions = {}
AddEventHandler('pf-government:server:workOrderCompleted', function(order) completions[#completions + 1] = order end)

-- city-wide state: every district healthy, no orders
local function healthy()
    MySQL.update.await('UPDATE pf_gov_infra_district_state SET pothole_density = 0, road_condition = 100, street_light_health = 100, traffic_light_health = 100, maintenance_backlog = 0')
    MySQL.query.await('DELETE FROM pf_gov_work_orders')
    MySQL.query.await('DELETE FROM pf_gov_work_claims')
    MySQL.query.await('DELETE FROM pf_gov_work_payments')
    for k in pairs(WorkOrders.active) do WorkOrders.active[k] = nil end
end

local STAFF, CSER, GARB, OTHER = 1, 2, 3, 4
local SITE = Config.WorkOrders.Sites.police_mrpd[1] -- Legion Square
local seq = 0
BeforeEach = function()
    Mock.reset()
    seq = seq + 1
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    Mock.invokingResource = nil
    local staff = Mock.newPlayer(STAFF, 'STF' .. seq)
    staff.PlayerData.job = { name = 'government', grade = { level = 0 }, onduty = true }
    Mock.newPlayer(CSER, 'CSV' .. seq)
    local garb = Mock.newPlayer(GARB, 'GRB' .. seq)
    garb.PlayerData.job = { name = 'garbage', grade = { level = 0 }, onduty = true }
    Mock.newPlayer(OTHER, 'OTH' .. seq)
    for _, src in ipairs({ STAFF, CSER, GARB, OTHER }) do Mock.coords[src] = vector3(SITE.x + 1.0, SITE.y, SITE.z) end
    completions = {}
end

-- one order at Legion Square made through the export, as pf-justice or the admin menu would
local function legionOrder(fields)
    local spec = {
        kind = 'litter', district = 'police_mrpd', site = { x = SITE.x, y = SITE.y, z = SITE.z, r = 30.0, label = 'Legion Square' },
        units = 2, effect = { field = 'maintenance_backlog', delta = -400 }, source = { type = 'manual', id = 'spec' },
    }
    for k, v in pairs(fields or {}) do spec[k] = v end
    local res = WorkOrders.Create(spec)
    assert_true(res.ok, 'order: ' .. tostring(res.error) .. ' ' .. tostring(res.message))
    return res.workOrderId
end

-- claims a unit and works it on site for the kind's minimum time; returns the claim id
local function claimAndWork(orderId, src, kind)
    local cid = Mock.players[src].PlayerData.citizenid
    local c = WorkOrders.Claim(orderId, { kind = kind, cid = cid })
    assert_true(c.ok, 'claim: ' .. tostring(c.error) .. ' ' .. tostring(c.message))
    WorkOrders.SampleClaims(T)
    T = T + c.minSeconds
    WorkOrders.SampleClaims(T)
    return c.claimId, c
end

describe('schema', function()
    it('v5 and v6 apply on a fresh database; a second run applies nothing', function()
        assert_true(GovSchema.Ensure())
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-government' AND version IN (5, 6)")), 2)
        for _, t in ipairs({ 'pf_gov_work_orders', 'pf_gov_work_claims', 'pf_gov_work_payments', 'pf_gov_dept_qualifications', 'pf_gov_dept_shifts', 'pf_gov_dept_audit' }) do
            assert_eq(num(scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
        assert_eq(num(scalar("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_gov_budget_transactions' AND COLUMN_NAME IN ('idem_key', 'state', 'ledger_key')")), 3)
        GovSchema.__reset()
        assert_true(GovSchema.Ensure(), 'second run')
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-government'")), 6)
        -- every step is rerun-safe (an interrupted version restarts from its first step)
        for _, m in ipairs(GovSchema.Migrations) do
            if m.version >= 5 then for _, sql in ipairs(m.up) do MySQL.query.await(sql) end end
        end
    end)
    it('the infrastructure and the budgets start on top of it', function()
        InitializeBudgets()
        InitializeInfrastructure()
        assert_true(InitializeWorkOrders())
        assert_true(district('police_mrpd') ~= nil)
        -- corrections and doj are budget departments with their own society accounts
        assert_true(GetDepartmentMonthlyBudgetSnapshot('corrections') ~= nil)
        assert_eq(GetDepartmentMonthlyBudgetSnapshot('doj').linked_society_name, 'doj')
    end)
end)

describe('generator', function()
    it('a district over a threshold gets one order per rule, at its own sites, capped per district', function()
        healthy()
        RecalculateInfrastructureState()
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_work_orders')), 0, 'healthy city: no orders')
        -- Mission Row: potholes, dark streetlights, failing signals and a backlog: four rules cross
        assert_true(GetDistrictInfrastructureState('police_mrpd') ~= nil)
        local made = WorkOrders.OnInfrastructureTick({
            police_mrpd = { pothole_density = 40, road_condition = 100, street_light_health = 50, traffic_light_health = 50, maintenance_backlog = 5000 },
            downtown = { pothole_density = 25, road_condition = 100, street_light_health = 100, traffic_light_health = 100, maintenance_backlog = 0 },
            nowhere = { pothole_density = 99 },
        })
        assert_eq(made, 4, 'three for Mission Row (cap) and one for downtown')
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_work_orders WHERE district = 'police_mrpd' AND status = 'open'")), 3)
        local pot = MySQL.single.await("SELECT * FROM pf_gov_work_orders WHERE district = 'police_mrpd' AND source_id = 'police_mrpd:potholes'")
        assert_true(pot ~= nil, 'pothole rule first')
        assert_eq(pot.kind, 'pothole')
        assert_eq(pot.effect_field, 'pothole_density')
        assert_eq(num(pot.effect_delta), -6)
        assert_eq(pot.source_type, 'district')
        assert_eq(num(pot.pay_amount), 120)
        assert_eq(pot.pay_dept, 'dot')
        -- placed on a configured Mission Row site that hosts potholes
        local onSite = false
        for _, s in ipairs(Config.WorkOrders.Sites.police_mrpd) do
            if math.abs(num(pot.x) - s.x) < 0.01 and math.abs(num(pot.y) - s.y) < 0.01 then
                for _, k in ipairs(s.kinds) do if k == 'pothole' then onSite = true end end
            end
        end
        assert_true(onSite, 'pothole order at a pothole site')
        -- the next tick makes nothing new: the rules have open orders and the district is at its cap
        assert_eq(WorkOrders.OnInfrastructureTick({
            police_mrpd = { pothole_density = 40, road_condition = 100, street_light_health = 50, traffic_light_health = 50, maintenance_backlog = 5000 },
            downtown = { pothole_density = 25 },
        }), 0)
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_work_orders')), 4)
    end)
    it('runs from the real simulation tick, from the saved district state', function()
        healthy()
        setDistrict('industrial', { pothole_density = 60 })
        InitializeInfrastructure()   -- loads the saved rows and ticks once (the generator runs inside)
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_work_orders WHERE district = 'industrial' AND kind = 'pothole'")), 1)
    end)
    it('a configured city event leaves one order at its position; the same event never makes two', function()
        healthy()
        local ev = { id = 9001, kind = 'crime.robbery.store', title = 'Store robbed on Davis Ave', coords = vector3(-46.0, -1757.0, 29.4) }
        TriggerEvent('pf-services:cityEvent', ev)
        TriggerEvent('pf-services:cityEvent', ev)
        local rows = MySQL.query.await('SELECT * FROM pf_gov_work_orders')
        assert_eq(#rows, 1)
        assert_eq(rows[1].kind, 'graffiti')
        assert_eq(rows[1].district, 'residential', 'nearest configured site')
        assert_eq(rows[1].source_type, 'event')
        assert_eq(rows[1].source_id, '9001')
        assert_eq(rows[1].idem_key, 'pf-government:wo:event:9001')
        assert_true(math.abs(num(rows[1].x) - -46.0) < 0.01, 'at the event')
        -- severe weather is city-wide (no position): storm debris goes to a district site
        TriggerEvent('pf-services:cityEvent', { id = 9100, kind = 'weather.severe', title = 'Thunderstorm warning' })
        TriggerEvent('pf-services:cityEvent', { id = 9100, kind = 'weather.severe', title = 'Thunderstorm warning' })
        local storm = MySQL.query.await("SELECT * FROM pf_gov_work_orders WHERE source_id = '9100'")
        assert_eq(#storm, 1, 'one order per weather event')
        assert_eq(storm[1].kind, 'litter')
        local placed = false
        for _, site in ipairs(Config.WorkOrders.Sites[storm[1].district] or {}) do
            if math.abs(num(storm[1].x) - site.x) < 0.01 and math.abs(num(storm[1].y) - site.y) < 0.01 then placed = true end
        end
        assert_true(placed, 'at a site of ' .. tostring(storm[1].district))
        assert_true(storm[1].district ~= 'residential', 'not the district that already has an open order')
        TriggerEvent('pf-services:cityEvent', { id = 9101, kind = 'weather.severe', district = 'industrial' })
        assert_eq(MySQL.single.await("SELECT district FROM pf_gov_work_orders WHERE source_id = '9101'").district, 'industrial')
        MySQL.query.await("DELETE FROM pf_gov_work_orders WHERE source_id IN ('9100', '9101')")
        -- kinds not configured, events without coords or without an id: nothing
        TriggerEvent('pf-services:cityEvent', { id = 9002, kind = 'gov.tax.changed', coords = vector3(0, 0, 0) })
        TriggerEvent('pf-services:cityEvent', { id = 9003, kind = 'crime.robbery.store' })
        TriggerEvent('pf-services:cityEvent', { kind = 'crime.robbery.store', coords = vector3(-46.0, -1757.0, 29.4) })
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_work_orders')), 1)
    end)
end)

describe('claims and units', function()
    it('one unit per claim with a TTL; a citizen holds one claim; units cannot be over-claimed', function()
        healthy()
        local id = legionOrder({ units = 2 })
        local a = WorkOrders.Claim(id, { kind = 'cs', cid = 'CSV' .. seq })
        assert_true(a.ok)
        assert_eq(a.expiresAt, T + Config.WorkOrders.ClaimSeconds)
        assert_eq(MySQL.single.await('SELECT status FROM pf_gov_work_orders WHERE id = ?', { id }).status, 'in_progress')
        -- the same claim again (a lost answer) is the same unit
        local again = WorkOrders.Claim(id, { kind = 'cs', cid = 'CSV' .. seq })
        assert_true(again.duplicate)
        assert_eq(again.claimId, a.claimId)
        local other = legionOrder({ kind = 'park', units = 1 })
        assert_eq(WorkOrders.Claim(other, { kind = 'cs', cid = 'CSV' .. seq }).error, 'conflict', 'one claim at a time')
        assert_true(WorkOrders.Claim(id, { kind = 'cs', cid = 'OTH' .. seq }).ok)
        assert_eq(WorkOrders.Claim(id, { kind = 'cs', cid = 'ZZZ' .. seq }).error, 'conflict', 'both units taken')
        -- the TTL frees the unit
        T = T + Config.WorkOrders.ClaimSeconds + 1
        local swept = WorkOrders.Sweep(T)
        assert_eq(swept.claims, 2)
        assert_eq(MySQL.single.await('SELECT state FROM pf_gov_work_claims WHERE id = ?', { a.claimId }).state, 'expired')
        assert_eq(MySQL.single.await('SELECT status FROM pf_gov_work_orders WHERE id = ?', { id }).status, 'open', 'idle again')
        assert_eq(WorkOrders.Report(a.claimId, { src = CSER }).error, 'invalid_state')
        assert_true(WorkOrders.Claim(id, { kind = 'cs', cid = 'ZZZ' .. seq }).ok)
    end)
    it('staff and job claimants: on duty, the right job and permission, the right kind', function()
        healthy()
        local litter = legionOrder()
        local pothole = legionOrder({ kind = 'pothole', effect = { field = 'pothole_density', delta = -4 } })
        assert_eq(WorkOrders.Claim(pothole, { kind = 'job', cid = 'GRB' .. seq }).error, 'no_permission', 'garbage: litter only')
        assert_eq(WorkOrders.Claim(litter, { kind = 'staff', cid = 'OTH' .. seq }).error, 'no_permission')
        assert_eq(WorkOrders.Claim(litter, { kind = 'job', cid = 'NOBODY' }).error, 'offline')
        Mock.players[GARB].PlayerData.job.onduty = false
        assert_eq(WorkOrders.Claim(litter, { kind = 'job', cid = 'GRB' .. seq }).error, 'not_on_duty')
        Mock.players[GARB].PlayerData.job.onduty = true
        assert_true(WorkOrders.Claim(litter, { kind = 'job', cid = 'GRB' .. seq }).ok)
        assert_true(WorkOrders.Claim(pothole, { kind = 'staff', cid = 'STF' .. seq }).ok)
        local noCs = legionOrder({ kind = 'park', csEligible = false })
        assert_eq(WorkOrders.Claim(noCs, { kind = 'cs', cid = 'CSV' .. seq }).error, 'invalid_state')
    end)
    it('a unit needs the claimant in person, on foot, inside the site, for the minimum time', function()
        healthy()
        local id = legionOrder({ units = 1 })
        local c = WorkOrders.Claim(id, { kind = 'cs', cid = 'CSV' .. seq })
        assert_eq(c.minSeconds, Config.WorkOrders.MinUnitSeconds.litter)
        -- someone else cannot report it
        assert_eq(WorkOrders.Report(c.claimId, { src = OTHER }).error, 'no_permission')
        -- far away
        Mock.coords[CSER] = vector3(SITE.x + 200.0, SITE.y, SITE.z)
        WorkOrders.SampleClaims(T)
        assert_eq(WorkOrders.Report(c.claimId, { src = CSER }).error, 'too_far')
        -- on site, but only just arrived
        Mock.coords[CSER] = vector3(SITE.x + 5.0, SITE.y, SITE.z)
        WorkOrders.SampleClaims(T)
        T = T + 30
        local early = WorkOrders.Report(c.claimId, { src = CSER })
        assert_eq(early.error, 'too_soon')
        assert_eq(early.remaining, c.minSeconds - 30)
        -- leaving the site breaks the stretch
        T = T + 5
        Mock.coords[CSER] = vector3(SITE.x + 200.0, SITE.y, SITE.z)
        WorkOrders.SampleClaims(T)
        Mock.coords[CSER] = vector3(SITE.x + 5.0, SITE.y, SITE.z)
        T = T + 5
        WorkOrders.SampleClaims(T)
        T = T + c.minSeconds - 10
        assert_eq(WorkOrders.Report(c.claimId, { src = CSER }).error, 'too_soon', 'the clock restarted')
        -- in a vehicle
        T = T + 20
        Mock.vehicleOf[CSER] = 77
        assert_eq(WorkOrders.Report(c.claimId, { src = CSER }).error, 'invalid_state')
        Mock.vehicleOf[CSER] = nil
        WorkOrders.SampleClaims(T)
        T = T + c.minSeconds
        assert_eq(num(scalar('SELECT units_done FROM pf_gov_work_orders WHERE id = ?', { id })), 0, 'nothing counted yet')
        local res = WorkOrders.Report(c.claimId, { src = CSER }, { key = 'pf-justice:cs:task77' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.unitsDone, 1)
        assert_true(res.completed)
        -- the same report again is the same unit; the key cannot be reused for another claim
        local dup = WorkOrders.Report(c.claimId, { src = CSER }, { key = 'pf-justice:cs:task77' })
        assert_true(dup.ok and dup.duplicate)
        assert_eq(num(scalar('SELECT units_done FROM pf_gov_work_orders WHERE id = ?', { id })), 1)
        local id2 = legionOrder({ kind = 'park' })
        local c2 = claimAndWork(id2, CSER, 'cs')
        assert_eq(WorkOrders.Report(c2, { src = CSER }, { key = 'pf-justice:cs:task77' }).error, 'key_reused')
    end)
end)

describe('effects on the district', function()
    it('every unit changes the saved row; completion fires the event; the next tick keeps the repair', function()
        healthy()
        -- downtown is the control: same potholes, same DOT stage, no repair
        setDistrict('police_mrpd', { pothole_density = 40 })
        setDistrict('downtown', { pothole_density = 40 })
        InitializeInfrastructure()   -- memory from the saved rows (one tick of drift)
        local start = num(district('police_mrpd').pothole_density)
        assert_eq(num(district('downtown').pothole_density), start)
        MySQL.query.await('DELETE FROM pf_gov_work_orders')
        local id = legionOrder({ kind = 'pothole', units = 2, effect = { field = 'pothole_density', delta = -9 } })
        local c1 = claimAndWork(id, CSER, 'cs')
        assert_true(WorkOrders.Report(c1, { src = CSER }).ok)
        assert_near(num(district('police_mrpd').pothole_density), start - 4.5, 0.01, 'first unit saved')
        local c2 = claimAndWork(id, OTHER, 'cs')
        local res = WorkOrders.Report(c2, { src = OTHER })
        assert_true(res.ok and res.completed)
        local repaired = num(district('police_mrpd').pothole_density)
        assert_near(repaired, start - 9, 0.01, 'whole effect saved')
        local o = MySQL.single.await('SELECT * FROM pf_gov_work_orders WHERE id = ?', { id })
        assert_eq(o.status, 'completed')
        assert_eq(num(o.completed_at), T)
        assert_eq(#completions, 1)
        assert_eq(completions[1].id, id)
        assert_eq(completions[1].district, 'police_mrpd')
        assert_eq(completions[1].unitsDone, 2)
        -- the simulation continues from the repaired value (incremental drift), it does not undo it
        RecalculateInfrastructureState()
        RecalculateInfrastructureState()
        local after, control = num(district('police_mrpd').pothole_density), num(district('downtown').pothole_density)
        assert_true(control ~= start, 'the simulation drifted')
        assert_near(after, control - 9, 0.01, 'two ticks later the repaired district is still 9 better')
        -- a completed order takes no more units
        assert_eq(WorkOrders.Claim(id, { kind = 'cs', cid = 'ZZZ' .. seq }).error, 'invalid_state')
    end)
    it('a repair never makes a district worse', function()
        assert_eq(select(2, ApplyDistrictWorkEffect('police_mrpd', 'pothole_density', 5)), 'bad_args')
        assert_eq(select(2, ApplyDistrictWorkEffect('police_mrpd', 'street_light_health', -5)), 'bad_args')
        assert_eq(select(2, ApplyDistrictWorkEffect('police_mrpd', 'power_stage', -1)), 'bad_args')
        assert_eq(select(2, ApplyDistrictWorkEffect('atlantis', 'pothole_density', -1)), 'not_found')
        setDistrict('police_mrpd', { maintenance_backlog = 100 })
        InitializeInfrastructure()
        assert_true(ApplyDistrictWorkEffect('police_mrpd', 'maintenance_backlog', -5000))
        assert_eq(num(district('police_mrpd').maintenance_backlog), 0, 'clamped at zero')
    end)
end)

describe('payouts', function()
    it('staff and job workers are paid once each from the department society; community service is not', function()
        healthy()
        fund('dot', 5000, 'spec:fund:dot:' .. seq)
        local dot0 = society('dot')
        local id = legionOrder({ kind = 'litter', units = 3, payable = { amount = 100, from = 'dot' } })
        local cA = claimAndWork(id, STAFF, 'staff')
        assert_true(WorkOrders.Report(cA, { src = STAFF }).ok)
        local cB = claimAndWork(id, STAFF, 'staff')
        assert_true(WorkOrders.Report(cB, { src = STAFF }).ok)
        local cC = claimAndWork(id, CSER, 'cs')
        local done = WorkOrders.Report(cC, { src = CSER })
        assert_true(done.completed)
        local pays = MySQL.query.await('SELECT * FROM pf_gov_work_payments WHERE work_order_id = ?', { id })
        assert_eq(#pays, 1, 'one payout: the staff worker; none for community service')
        assert_eq(pays[1].citizenid, 'STF' .. seq)
        assert_eq(num(pays[1].amount), 200, 'two units at 100')
        assert_eq(pays[1].state, 'paid')
        local base = ('pf-government:wo:%d:pay:STF%d'):format(id, seq)
        assert_eq(pays[1].ledger_key, base .. ':1')
        assert_eq(Mock.players[STAFF].PlayerData.money.bank, 200)
        assert_eq(Mock.players[CSER].PlayerData.money.bank, 0)
        assert_eq(society('dot'), dot0 - 200)
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { base .. ':1' })
        assert_eq(tx.from_account, 'society:dot')
        assert_eq(tx.to_account, 'player:STF' .. seq .. ':bank')
        -- the department's books show it once
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_budget_transactions WHERE idem_key = ? AND department = 'dot' AND state = 'applied'", { base .. ':1' })), 1)
        -- settling again pays nothing more
        WorkOrders.SettlePayments(T + 99999)
        WorkOrders.Sweep(T + 99999)
        assert_eq(Mock.players[STAFF].PlayerData.money.bank, 200)
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ?', { base .. '%' })), 1)
    end)
    it('a payout the ledger refuses (empty society) is retried later under the next numbered key', function()
        healthy()
        local gov0 = society('government')
        if gov0 > 0 then assert_true((exports['pfm-banking']:RemoveMoney('government', gov0, 'empty for spec', 'spec:empty:' .. seq))) end
        local id = legionOrder({ kind = 'park', units = 1, payable = { amount = 150, from = 'government' } })
        local c = claimAndWork(id, STAFF, 'staff')
        local res = WorkOrders.Report(c, { src = STAFF })
        assert_true(res.ok and res.completed, 'the unit counts whatever the bank says')
        local base = ('pf-government:wo:%d:pay:STF%d'):format(id, seq)
        local p = MySQL.single.await('SELECT * FROM pf_gov_work_payments WHERE work_order_id = ?', { id })
        assert_eq(p.state, 'owed')
        assert_eq(num(p.attempts), 1)
        assert_eq(MySQL.single.await('SELECT state FROM pf_transactions WHERE idempotency_key = ?', { base .. ':1' }).state, 'failed')
        assert_eq(Mock.players[STAFF].PlayerData.money.bank, 0)
        -- not before the retry time
        WorkOrders.SettlePayments(T + 1)
        assert_eq(num(scalar('SELECT attempts FROM pf_gov_work_payments WHERE id = ?', { p.id })), 1)
        fund('government', 1000, 'spec:fund:gov:' .. seq)
        T = T + Config.WorkOrders.PayRetrySeconds + 1
        WorkOrders.Sweep(T)
        p = MySQL.single.await('SELECT * FROM pf_gov_work_payments WHERE id = ?', { p.id })
        assert_eq(p.state, 'paid')
        assert_eq(p.ledger_key, base .. ':2', 'a new numbered key after the clear refusal')
        assert_eq(Mock.players[STAFF].PlayerData.money.bank, 150)
    end)
    it('an unclear payout is held: never paid again under a new key', function()
        healthy()
        fund('dot', 1000, 'spec:fund:dot2:' .. seq)
        local id = legionOrder({ kind = 'litter', units = 1, payable = { amount = 80, from = 'dot' } })
        local base = ('pf-government:wo:%d:pay:GRB%d'):format(id, seq)
        -- a first attempt the bank left pending (crash mid-transfer)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES (?, ?, 'wage', 'society:dot', ?, 80, 'pending')]], { 'TXSPEC' .. seq, base .. ':1', 'player:GRB' .. seq .. ':bank' })
        local c = claimAndWork(id, GARB, 'job')
        assert_true(WorkOrders.Report(c, { src = GARB }).completed)
        T = T + 99999
        WorkOrders.Sweep(T)
        local p = MySQL.single.await('SELECT * FROM pf_gov_work_payments WHERE work_order_id = ?', { id })
        assert_eq(p.state, 'owed')
        assert_eq(p.ledger_key, base .. ':1')
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ?', { base .. '%' })), 1, 'no second key')
        assert_eq(Mock.players[GARB].PlayerData.money.bank, 0)
        -- once the ledger settles it as completed, it is booked as paid (no new transfer)
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key = ?", { base .. ':1' })
        T = T + Config.WorkOrders.PayRetrySeconds + 1
        WorkOrders.Sweep(T)
        assert_eq(MySQL.single.await('SELECT state FROM pf_gov_work_payments WHERE id = ?', { p.id }).state, 'paid')
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ?', { base .. '%' })), 1)
    end)
end)

describe('expiry and cancellation', function()
    it('an order past its time expires with its claims; done units are still paid', function()
        healthy()
        fund('dot', 1000, 'spec:fund:dot3:' .. seq)
        local id = legionOrder({ kind = 'litter', units = 3, payable = { amount = 50, from = 'dot' }, expiresAt = T + 3600 })
        local c = claimAndWork(id, GARB, 'job')
        assert_true(WorkOrders.Report(c, { src = GARB }).ok)
        local open = WorkOrders.Claim(id, { kind = 'cs', cid = 'CSV' .. seq })
        assert_true(open.ok)
        assert_true(open.expiresAt <= T + 3600 - Config.WorkOrders.MinUnitSeconds.litter, 'a claim never outlives its order')
        T = T + 3601
        local swept = WorkOrders.Sweep(T)
        assert_eq(swept.orders, 1)
        assert_eq(MySQL.single.await('SELECT status FROM pf_gov_work_orders WHERE id = ?', { id }).status, 'expired')
        assert_eq(MySQL.single.await('SELECT state FROM pf_gov_work_claims WHERE id = ?', { open.claimId }).state, 'expired')
        assert_eq(Mock.players[GARB].PlayerData.money.bank, 50, 'the done unit is paid')
    end)
    it('cancel: only staff with the permission (or an allowlisted resource); open claims are released', function()
        healthy()
        local id = legionOrder()
        local c = WorkOrders.Claim(id, { kind = 'cs', cid = 'CSV' .. seq })
        assert_eq(WorkOrders.Cancel(id, 'x', { actor = { src = OTHER } }).error, 'no_permission')
        local res = WorkOrders.Cancel(id, 'Duplicate report', { actor = { src = STAFF } })
        assert_true(res.ok)
        assert_eq(MySQL.single.await('SELECT status FROM pf_gov_work_orders WHERE id = ?', { id }).status, 'cancelled')
        assert_eq(MySQL.single.await('SELECT state FROM pf_gov_work_claims WHERE id = ?', { c.claimId }).state, 'released')
        assert_true(WorkOrders.Cancel(id, 'again', { actor = { src = STAFF } }).duplicate)
    end)
    it('release frees the unit and reopens an idle order', function()
        healthy()
        local id = legionOrder({ units = 1 })
        local c = WorkOrders.Claim(id, { kind = 'cs', cid = 'CSV' .. seq })
        assert_true(WorkOrders.Release(c.claimId, 'left').ok)
        assert_eq(MySQL.single.await('SELECT status FROM pf_gov_work_orders WHERE id = ?', { id }).status, 'open')
        assert_true(WorkOrders.Release(c.claimId, 'left').duplicate)
        assert_true(WorkOrders.Claim(id, { kind = 'cs', cid = 'OTH' .. seq }).ok)
    end)
end)

describe('exports (the contract pf-justice and the apps use)', function()
    it('list and get return public orders (no citizen ids) with filters', function()
        healthy()
        local a = legionOrder({ kind = 'litter' })
        local b = legionOrder({ kind = 'park', csEligible = false })
        local resFar = WorkOrders.Create({ kind = 'pothole', district = 'industrial', site = { x = 800.0, y = -2200.0, z = 29.4, r = 30.0 },
            units = 1, effect = { field = 'pothole_density', delta = -3 } })
        assert_true(resFar.ok)
        WorkOrders.Claim(a, { kind = 'cs', cid = 'CSV' .. seq })
        Mock.invokingResource = 'pf-justice'
        local list = exports['pf-government']:ListWorkOrders({ csEligible = true, near = { x = SITE.x, y = SITE.y, z = SITE.z, r = 50.0 } })
        assert_true(list.ok)
        assert_eq(#list.list, 1)
        assert_eq(list.list[1].id, a)
        assert_eq(list.list[1].unitsOpen, 1, 'two units, one claimed')
        assert_eq(list.list[1].status, 'in_progress')
        assert_true(list.list[1].distance ~= nil)
        local all = exports['pf-government']:ListWorkOrders({ kinds = { 'park', 'pothole' } })
        assert_eq(#all.list, 2)
        assert_eq(exports['pf-government']:ListWorkOrders({ district = 'industrial' }).list[1].id, resFar.workOrderId)
        assert_eq(exports['pf-government']:ListWorkOrders({ limit = 500 }).error, 'bad_args')
        local got = exports['pf-government']:GetWorkOrder(b)
        assert_true(got.ok)
        assert_false(got.order.csEligible)
        assert_eq(got.order.label, 'Park upkeep')
        assert_eq(exports['pf-government']:GetWorkOrder(999999).error, 'not_found')
        local enc = json.encode(list)
        assert_true(not enc:find('CSV' .. seq, 1, true), 'no citizen id in a list')
    end)
    it('pf-justice claims and reports through the exports; other resources are refused', function()
        healthy()
        local id = legionOrder({ units = 1 })
        Mock.invokingResource = 'some-script'
        assert_eq(exports['pf-government']:ClaimWorkOrder(id, { kind = 'cs', cid = 'CSV' .. seq }).error, 'not_allowed')
        assert_eq(exports['pf-government']:CreateWorkOrder({}).error, 'not_allowed')
        Mock.invokingResource = 'pf-justice'
        local c = exports['pf-government']:ClaimWorkOrder(id, { kind = 'cs', cid = 'CSV' .. seq, ref = 'task:1' })
        assert_true(c.ok, tostring(c.error))
        WorkOrders.SampleClaims(T)
        T = T + c.minSeconds
        local r = exports['pf-government']:ReportWorkUnit(c.claimId, { src = CSER }, { key = 'pf-justice:cs:41' })
        assert_true(r.ok and r.completed, tostring(r.error))
        assert_eq(MySQL.single.await('SELECT ref FROM pf_gov_work_claims WHERE id = ?', { c.claimId }).ref, 'task:1')
        assert_eq(exports['pf-government']:CancelWorkOrder(id, 'x').error, 'not_allowed')
    end)
end)
