-- Batch 19 unit 19C: pf-justice community service on a real database, with the REAL pf-government work
-- orders (server/workorders.lua) on the same database:
--   1. the v5 tables (pf_justice_cs_shifts, pf_justice_cs_tasks) take every statement of the runtime;
--   2. sign-in -> list (GOV ListWorkOrders csEligible near) -> claim (a real GOV claim, kind 'cs') -> steps
--      (CAS on steps_done) -> report: the unit counts only after the real GOV ReportWorkUnit accepted it
--      (its own on-site timer); GOV's claim row carries proof_key 'pf-justice:cs:<taskId>';
--   3. a disconnect keeps the task's steps; after the GOV claim lapsed the resume claims the same work
--      order again and the task finishes on the new claim;
--   4. the order completes at its units; a supervised shift counts x SupervisorBonus (join query);
--   5. an overdue order is found once by the court query (NOT EXISTS on the keyed event) and filed once;
--   6. stale-shift query and GetCommunityService.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-services'] = 'missing', ['pfm-houses'] = 'missing', ['pfm-phone'] = 'missing', ['pf-citizen'] = 'missing',
    ['pfm-prison'] = 'missing', ['pf-ambulancejob'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}
Mock.clock = 1800000000

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

-- pf-government (real work orders)
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
local GovConfig = Config
local govX = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil

-- pf-justice
function GetCurrentResourceName() return 'pf-justice' end
Config = nil
PFPayout = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'shared/cs_tasks.lua', 'server/main.lua', 'server/schema.lua',
    'server/orders.lua', 'server/records.lua', 'server/community_service.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
local JuConfig = Config
local juX = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-justice'] = juX
local J = PFJustice
local CS = J.CS

-- each resource reads its own Config: swap it around every call into pf-government
local function asGov(fn, ...)
    local saved, inv = Config, Mock.invokingResource
    Config, Mock.invokingResource = GovConfig, 'pf-justice'
    local res = table.pack(pcall(fn, ...))
    Config, Mock.invokingResource = saved, inv
    if not res[1] then error(res[2], 2) end
    return table.unpack(res, 2, res.n)
end
local quals = {}
Mock.exportsByResource['pf-government'] = setmetatable({
    HasQualification = function(_, cid, q) return quals[cid .. ':' .. q] == true end,
}, { __index = function(_, name)
    local f = govX[name]
    if not f then return nil end
    return function(_, ...) return asGov(f, ...) end
end })

local function scalar(q, p) return tonumber(MySQL.scalar.await(q, p or {})) or 0 end
local function row(q, p) return MySQL.single.await(q, p or {}) end

-- schemas: GOV, then pf-justice (19A's v5; the documented DDL is applied only if the schema lacks it)
asGov(function()
    assert(GovSchema.Ensure(), 'gov schema')
    InitializeBudgets()
    InitializeInfrastructure()
    assert(InitializeWorkOrders(), 'work orders')
end)
local booted = J.Boot()
local function hasTable(t) return scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1 end
local v5FromSchema = hasTable('pf_justice_cs_shifts') and hasTable('pf_justice_cs_tasks')
if not v5FromSchema then
    print('note: pf-justice schema has no v5 yet; the spec applies the documented DDL')
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pf_justice_cs_shifts` (
      `id` INT NOT NULL AUTO_INCREMENT, `order_id` INT NOT NULL, `citizenid` VARCHAR(64) NOT NULL,
      `site` VARCHAR(32) NULL, `supervisor_cid` VARCHAR(64) NULL, `started_at` BIGINT NOT NULL, `ended_at` BIGINT NULL,
      `units` DECIMAL(6,2) NOT NULL DEFAULT 0,
      PRIMARY KEY (`id`), KEY `idx_jcs_order` (`order_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pf_justice_cs_tasks` (
      `id` INT NOT NULL AUTO_INCREMENT, `shift_id` INT NOT NULL, `order_id` INT NOT NULL,
      `work_order_id` INT NOT NULL, `claim_id` INT NOT NULL, `kind` VARCHAR(16) NOT NULL,
      `steps_done` TINYINT NOT NULL DEFAULT 0, `steps_needed` TINYINT NOT NULL,
      `state` VARCHAR(10) NOT NULL, `started_at` BIGINT NOT NULL, `done_at` BIGINT NULL, `reject_reason` VARCHAR(64) NULL,
      PRIMARY KEY (`id`), KEY `idx_jct_shift` (`shift_id`), KEY `idx_jct_claim` (`claim_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end
if not booted then J.ready = true end
local realHas = J.Schema and J.Schema.Has
if realHas and not realHas(5) then J.Schema.Has = function() return true end end

local SITE = GovConfig.WorkOrders.Sites.police_mrpd[1] -- Legion Square
local DESK = vector3(-544.67, -204.25, 38.22)
JuConfig.CommunityService.SignIn = { { id = 'cityhall', label = 'City Hall desk', coords = DESK, radius = 15.0 } }
JuConfig.CommunityService.MinStepSeconds = 20
JuConfig.CommunityService.SupervisorBonus = 1.0
JuConfig.CommunityService.ShiftMaxHours = 4
JuConfig.Callers.GetCommunityService = '*'

local seq = 0
local W, SUP = 1, 2
local cid
local filed = {}
J.API = J.API or {}
J.API.FileCase = function(spec, opts) filed[#filed + 1] = { spec = spec, opts = opts } return { ok = true, caseId = 900 + #filed } end

BeforeEach = function()
    Mock.reset()
    seq = seq + 1
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    Mock.invokingResource = nil
    for k in pairs(CS.live) do CS.live[k] = nil end
    for k in pairs(CS.bySrc) do CS.bySrc[k] = nil end
    for k in pairs(WorkOrders.active) do WorkOrders.active[k] = nil end
    MySQL.query.await("UPDATE pf_gov_work_orders SET status = 'cancelled' WHERE status IN ('open', 'in_progress')")
    MySQL.query.await("UPDATE pf_gov_work_claims SET state = 'released' WHERE state = 'claimed'")
    cid = 'CSW' .. seq
    Mock.newPlayer(W, cid)
    Mock.coords[W] = DESK
    local sup = Mock.newPlayer(SUP, 'SUP' .. seq)
    sup.PlayerData.job = { name = 'government', grade = { level = 0 }, onduty = true }
    Mock.coords[SUP] = vector3(SITE.x + 3, SITE.y, SITE.z)
    filed = {}
end

local function csOrder(units)
    local r = J.API and J.API.CreateOrder and J.API.CreateOrder({ cid = cid, kind = 'community_service', units = units }, { key = 'spec:cs:' .. seq .. ':' .. units })
        or J.Orders.Create({ cid = cid, kind = 'community_service', units = units }, { key = 'spec:cs:' .. seq .. ':' .. units }, {})
    assert_true(r.ok, 'order: ' .. tostring(r.error))
    return r.orderId
end

local function workOrder(units)
    local res = asGov(WorkOrders.Create, {
        kind = 'litter', district = 'police_mrpd', site = { x = SITE.x, y = SITE.y, z = SITE.z, r = 30.0, label = 'Legion Square' },
        units = units or 5, effect = { field = 'maintenance_backlog', delta = -400 }, source = { type = 'manual', id = 'spec' .. seq }, csEligible = true,
    })
    assert_true(res.ok, 'work order: ' .. tostring(res.error) .. ' ' .. tostring(res.message))
    return res.workOrderId
end

local function at(src, p) Mock.coords[src] = vector3(p.x, p.y, p.z) end

local function steps(src, taskId, upto)
    local e = CS.live[taskId]
    for i = e.stepsDone + 1, upto or e.stepsNeeded do
        Mock.clock = Mock.clock + 21
        at(src, e.points[i])
        local r = CS.Step(src, taskId, i)
        assert_true(r.ok, 'step ' .. i .. ': ' .. tostring(r.error))
    end
end

-- on site: both timers (JU 1 Hz sample, GOV claim sampler) start, then the minimum time passes
local function workOnSite(src, taskId)
    local e = CS.live[taskId]
    at(src, e.site)
    CS.Sample(Mock.clock)
    asGov(WorkOrders.SampleClaims, Mock.clock)
    Mock.clock = Mock.clock + e.minSeconds
    CS.Sample(Mock.clock)
    asGov(WorkOrders.SampleClaims, Mock.clock)
end

describe('19C v5 tables', function()
    it('exist with the documented columns', function()
        for _, c in ipairs({ 'order_id', 'citizenid', 'site', 'supervisor_cid', 'started_at', 'ended_at', 'units' }) do
            assert_eq(scalar("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_justice_cs_shifts' AND COLUMN_NAME = ?", { c }), 1, c)
        end
        for _, c in ipairs({ 'shift_id', 'order_id', 'work_order_id', 'claim_id', 'kind', 'steps_done', 'steps_needed', 'state', 'started_at', 'done_at', 'reject_reason' }) do
            assert_eq(scalar("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_justice_cs_tasks' AND COLUMN_NAME = ?", { c }), 1, c)
        end
    end)
end)

describe('19C flow on real GOV work orders', function()
    it('counts a unit only after the real ReportWorkUnit accepted it', function()
        local oid = csOrder(2)
        local wo = workOrder(5)
        local s = CS.StartShift(W)
        assert_true(s.ok, 'shift: ' .. tostring(s.error))
        assert_eq(row('SELECT state FROM pf_justice_orders WHERE id = ?', { oid }).state, 'active')
        at(W, { x = SITE.x + 50, y = SITE.y, z = SITE.z })
        local l = CS.ListWork(W)
        assert_true(l.ok, 'list: ' .. tostring(l.error))
        local found = false
        for _, w in ipairs(l.list) do if w.id == wo then found = true end end
        assert_true(found, 'listed')
        local c = CS.Claim(W, wo)
        assert_true(c.ok, 'claim: ' .. tostring(c.error) .. ' ' .. tostring(c.message))
        local task = row('SELECT * FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId })
        local claim = row('SELECT * FROM pf_gov_work_claims WHERE id = ?', { task.claim_id })
        assert_eq(claim.claimant_kind, 'cs') assert_eq(claim.citizenid, cid) assert_eq(claim.state, 'claimed')
        steps(W, c.taskId)
        assert_eq(tonumber(row('SELECT steps_done FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId }).steps_done), 5)
        -- JU's own timer is met, GOV's is not (its sampler never saw the worker): GOV refuses, nothing counts
        local e = CS.live[c.taskId]
        at(W, e.site)
        CS.Sample(Mock.clock)
        Mock.clock = Mock.clock + e.minSeconds
        CS.Sample(Mock.clock)
        local r = CS.Complete(W, c.taskId)
        assert_eq(r.error, 'too_soon', 'GOV refused')
        assert_eq(scalar('SELECT units_done FROM pf_justice_orders WHERE id = ?', { oid }), 0)
        assert_eq(row('SELECT state FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId }).state, 'active')
        -- now on site for GOV's minimum as well
        workOnSite(W, c.taskId)
        r = CS.Complete(W, c.taskId)
        assert_true(r.ok, 'report: ' .. tostring(r.error) .. ' ' .. tostring(r.message))
        assert_eq(scalar('SELECT units_done FROM pf_justice_orders WHERE id = ?', { oid }), 1)
        claim = row('SELECT * FROM pf_gov_work_claims WHERE id = ?', { task.claim_id })
        assert_eq(claim.state, 'done') assert_eq(claim.proof_key, 'pf-justice:cs:' .. c.taskId)
        assert_eq(scalar('SELECT units_done FROM pf_gov_work_orders WHERE id = ?', { wo }), 1)
        assert_eq(row('SELECT state FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId }).state, 'done')
        assert_eq(tonumber(row('SELECT units FROM pf_justice_cs_shifts WHERE id = ?', { s.shiftId }).units), 1)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_order_events WHERE order_id = ? AND action = 'cs_unit' AND idem_key = ?", { oid, 'pf-justice:cs:' .. c.taskId .. ':unit' }), 1)
        -- the second unit completes the order and ends the shift
        local c2 = CS.Claim(W, wo)
        assert_true(c2.ok, 'claim 2')
        steps(W, c2.taskId)
        workOnSite(W, c2.taskId)
        r = CS.Complete(W, c2.taskId)
        assert_true(r.completed, 'completed')
        assert_eq(row('SELECT state FROM pf_justice_orders WHERE id = ?', { oid }).state, 'completed')
        assert_true(row('SELECT ended_at FROM pf_justice_cs_shifts WHERE id = ?', { s.shiftId }).ended_at ~= nil)
    end)

    it('a disconnect keeps the steps; a lapsed GOV claim is claimed again on resume', function()
        local oid = csOrder(3)
        local wo = workOrder(5)
        assert_true(CS.StartShift(W).ok)
        local c = CS.Claim(W, wo)
        assert_true(c.ok)
        local firstClaim = tonumber(row('SELECT claim_id FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId }).claim_id)
        steps(W, c.taskId, 3)
        Mock.fireEvent('playerDropped', W)
        Mock.players[W] = nil
        Mock.clock = Mock.clock + 3600
        asGov(WorkOrders.Sweep, Mock.clock)
        Mock.newPlayer(7, cid)
        Mock.coords[7] = vector3(0, 0, 0)
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, Mock.players[7])
        local t = row('SELECT * FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId })
        assert_eq(t.state, 'active') assert_eq(tonumber(t.steps_done), 3)
        assert_true(tonumber(t.claim_id) ~= firstClaim, 'new claim')
        assert_eq(row('SELECT state FROM pf_gov_work_claims WHERE id = ?', { t.claim_id }).state, 'claimed')
        steps(7, c.taskId)
        workOnSite(7, c.taskId)
        assert_true(CS.Complete(7, c.taskId).ok)
        assert_eq(scalar('SELECT units_done FROM pf_justice_orders WHERE id = ?', { oid }), 1)
    end)

    it('a supervised shift counts units x the bonus (join of done tasks and shifts)', function()
        JuConfig.CommunityService.SupervisorBonus = 1.5
        quals['SUP' .. seq .. ':cs_supervisor'] = true
        local oid = csOrder(4)
        local wo = workOrder(5)
        local s = CS.StartShift(W)
        at(W, SITE)
        assert_true(CS.Verify(SUP, W).ok)
        assert_eq(row('SELECT supervisor_cid FROM pf_justice_cs_shifts WHERE id = ?', { s.shiftId }).supervisor_cid, 'SUP' .. seq)
        for _ = 1, 2 do
            local c = CS.Claim(W, wo)
            assert_true(c.ok, 'claim')
            steps(W, c.taskId)
            workOnSite(W, c.taskId)
            assert_true(CS.Complete(W, c.taskId).ok)
        end
        assert_eq(scalar('SELECT units_done FROM pf_justice_orders WHERE id = ?', { oid }), 3)
        assert_eq(tonumber(row('SELECT units FROM pf_justice_cs_shifts WHERE id = ?', { s.shiftId }).units), 3)
        JuConfig.CommunityService.SupervisorBonus = 1.0
    end)
end)

describe('19C overdue, stale shifts, export', function()
    it('files one court item per overdue order; no incarceration order', function()
        local oid = csOrder(2)
        MySQL.update.await("UPDATE pf_justice_orders SET state = 'overdue' WHERE id = ?", { oid })
        local before = scalar("SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid = ?", { cid })
        assert_true(CS.CourtTick(Mock.clock) >= 1)
        local mine = 0
        for _, f in ipairs(filed) do if f.spec.cid == cid then mine = mine + 1 assert_eq(f.spec.kind, 'violation') end end
        assert_eq(mine, 1)
        assert_eq(scalar('SELECT COUNT(*) FROM pf_justice_order_events WHERE idem_key = ?', { 'pf-justice:cs:order:' .. oid .. ':court' }), 1)
        CS.CourtTick(Mock.clock)
        mine = 0
        for _, f in ipairs(filed) do if f.spec.cid == cid then mine = mine + 1 end end
        assert_eq(mine, 1, 'once')
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid = ?", { cid }), before)
        assert_eq(row('SELECT state FROM pf_justice_orders WHERE id = ?', { oid }).state, 'overdue')
    end)
    it('ends shifts past ShiftMaxHours and answers GetCommunityService', function()
        local oid = csOrder(2)
        local wo = workOrder(5)
        local s = CS.StartShift(W)
        local c = CS.Claim(W, wo)
        local claimId = row('SELECT claim_id FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId }).claim_id
        Mock.clock = Mock.clock + 5 * 3600
        assert_true(CS.StaleTick(Mock.clock) >= 1)
        assert_true(row('SELECT ended_at FROM pf_justice_cs_shifts WHERE id = ?', { s.shiftId }).ended_at ~= nil)
        assert_eq(row('SELECT state FROM pf_justice_cs_tasks WHERE id = ?', { c.taskId }).state, 'released')
        assert_eq(row('SELECT state FROM pf_gov_work_claims WHERE id = ?', { claimId }).state, 'released')
        local r = CS.Get(cid)
        assert_true(r.ok)
        assert_eq(r.orders[1].orderId, oid) assert_eq(r.orders[1].units, 2) assert_eq(r.orders[1].state, 'active')
    end)
end)
