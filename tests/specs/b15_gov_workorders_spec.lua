-- Batch 15 unit 15E (mocked): pf-government work orders, keyed budget moves and the CreateBill
-- passthrough. The SQL paths run on a real database in b15_gov_workorders_realdb_spec and
-- b15_gov_budget_keys_realdb_spec; this spec covers what is decided before or around the database:
-- allowlists, argument checks, server-position proof, the per-unit effect split, the district effect
-- API, the generator's thresholds and cap, the ledger handling of keyed moves (unclear held, clear
-- failure -> next numbered key) and the config contract 15I and pf-justice read.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pfm-banking'] = true, ['pf-government'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
vec4 = vec4 or vector4
GlobalState = {}

local DB = { handlers = {}, log = {}, nextId = 100 }
local function on(fragment, fn) table.insert(DB.handlers, 1, { fragment, fn }) end
local function run(kind, q, p)
    DB.log[#DB.log + 1] = { kind = kind, q = q, p = p or {} }
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
local function logged(fragment)
    local out = {}
    for _, e in ipairs(DB.log) do if e.q:find(fragment, 1, true) then out[#out + 1] = e end end
    return out
end

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/budgets.lua', 'server/bills.lua',
    'server/infrastructure.lua', 'server/workorders.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function LogAudit() end
function NotifyGovernment() end
function DebugPrint() end
GovSchema.Ensure = function() return true end
local govX = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-government'] = govX
Mock.exportsByResource['__self'] = nil

-- the bank: balances and a ledger by key; `script` decides each transfer's answer
local bank = { balances = {}, tx = {}, calls = {}, script = nil }
local function ledgerAnswer(key, from, to, amount)
    bank.calls[#bank.calls + 1] = { key = key, from = from, to = to, amount = amount }
    local res = bank.script and bank.script(key) or { ok = true, state = 'completed', txId = 'TX' .. #bank.calls }
    if key then bank.tx[key] = { tx_id = res.txId or ('TX' .. #bank.calls), state = res.state, error = res.error } end
    return res
end
Mock.exportsByResource['pfm-banking'] = {
    GetAccount = function(_, name) return { account_name = name } end,
    CreateJobAccount = function() return true end,
    GetAccountBalance = function(_, name) return bank.balances[name] or 0 end,
    GetTransaction = function(_, key) return bank.tx[key] end,
    RemoveMoney = function(_, name, amount, reason, key)
        local res = ledgerAnswer(key, 'society:' .. name, 'system:pf-government', amount)
        if res.ok then bank.balances[name] = (bank.balances[name] or 0) - amount end
        return res.ok, res
    end,
    AddMoney = function(_, name, amount, reason, key)
        local res = ledgerAnswer(key, 'system:pf-government', 'society:' .. name, amount)
        if res.ok then bank.balances[name] = (bank.balances[name] or 0) + amount end
        return res.ok, res
    end,
    Transfer = function(_, opts) return ledgerAnswer(opts.key, opts.from, opts.to, opts.amount) end,
}

-- an in-memory pf_gov_budget_transactions keyed by idem_key, enough for the keyed-move path
local budgetRows = {}
local function installBudgetDb()
    budgetRows = {}
    on('FROM pf_gov_department_monthly_plans WHERE department = ? AND month_key = ?', function(p)
        return { id = 1, department = p[1], month_key = p[2], linked_society_name = p[1], approved_monthly_budget = 1000, spent_this_month = 0 }
    end)
    on('SELECT * FROM pf_gov_budget_transactions WHERE idem_key = ?', function(p) return budgetRows[p[1]] end)
    on('INSERT IGNORE INTO pf_gov_budget_transactions', function(p, kind)
        local key = p[11]
        if budgetRows[key] then return 0 end
        budgetRows[key] = { id = #DB.log, department = p[1], month_key = p[2], transaction_type = p[3], category = p[4], amount = p[5],
            idem_key = key, state = 'pending', ledger_key = p[12] }
        return budgetRows[key].id
    end)
    on('UPDATE pf_gov_budget_transactions SET', function(p, kind)
        for _, r in pairs(budgetRows) do
            if r.id == p[#p] then
                local q = DB.log[#DB.log].q
                if q:find("state = 'applied'", 1, true) then
                    if r.state == 'applied' then return 0 end
                    r.state = 'applied'
                elseif q:find("state = 'failed'", 1, true) then
                    if r.state ~= 'pending' then return 0 end
                    r.state = 'failed'
                elseif q:find("state = 'pending', ledger_key = ?, society_before", 1, true) then
                    if r.state ~= 'failed' then return 0 end
                    r.state, r.ledger_key = 'pending', p[1]
                elseif q:find('SET ledger_key = ?', 1, true) then
                    r.ledger_key = p[1]
                end
                return 1
            end
        end
        return 0
    end)
end

local CS, FAR, CAR = 1, 2, 3
BeforeEach = function()
    Mock.reset()
    DB.handlers, DB.log = {}, {}
    bank.calls, bank.tx, bank.script = {}, {}, nil
    bank.balances = { police = 10000, government = 50000 }
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    Mock.invokingResource = nil
    Mock.newPlayer(CS, 'CSV1')
    Mock.newPlayer(FAR, 'FAR1')
    Mock.newPlayer(CAR, 'CAR1')
end

local SITE = { x = 195.2, y = -933.9, z = 30.7, r = 30.0 }
local function spec(fields)
    local s = { kind = 'litter', district = 'police_mrpd', site = { x = SITE.x, y = SITE.y, z = SITE.z, r = SITE.r }, units = 2,
        effect = { field = 'maintenance_backlog', delta = -400 } }
    for k, v in pairs(fields or {}) do s[k] = v end
    return s
end

describe('exports: allowlists and arguments', function()
    it('an unknown resource is refused by every writing export', function()
        Mock.invokingResource = 'random-script'
        assert_eq(exports['pf-government']:CreateWorkOrder(spec()).error, 'not_allowed')
        assert_eq(exports['pf-government']:ClaimWorkOrder(1, { kind = 'cs', cid = 'CSV1' }).error, 'not_allowed')
        assert_eq(exports['pf-government']:ReportWorkUnit(1, { src = CS }).error, 'not_allowed')
        assert_eq(exports['pf-government']:ReleaseWorkClaim(1, 'x').error, 'not_allowed')
        assert_eq(exports['pf-government']:CancelWorkOrder(1, 'x').error, 'not_allowed')
        assert_eq(#logged('pf_gov_work'), 0, 'nothing reached the database')
    end)
    it('reads are open', function()
        Mock.invokingResource = 'random-script'
        assert_true(exports['pf-government']:ListWorkOrders({}).ok)
    end)
    it('community service claims come only from the order owner (pf-justice)', function()
        Config.WorkOrders.Callers.ClaimWorkOrder['pfm-adminmenu'] = true
        Mock.invokingResource = 'pfm-adminmenu'
        assert_eq(exports['pf-government']:ClaimWorkOrder(1, { kind = 'cs', cid = 'CSV1' }).error, 'not_allowed')
        Config.WorkOrders.Callers.ClaimWorkOrder['pfm-adminmenu'] = nil
    end)
    it('a work order spec is checked field by field; a repair can never worsen a district', function()
        local bad = {
            { kind = 'arson' }, { district = 'atlantis' }, { units = 0 }, { units = 21 }, { units = 1.5 },
            { site = { x = 0 / 0, y = 0, z = 0, r = 10 } }, { site = { x = 1, y = 1, z = 1, r = 500 } }, { site = 'here' },
            { effect = { field = 'maintenance_backlog', delta = 400 } }, { effect = { field = 'street_light_health', delta = -5 } },
            { effect = { field = 'power_stage', delta = -1 } }, { effect = { field = 'pothole_density', delta = -999 } },
            { payable = { amount = 50, from = 'mafia' } }, { payable = { amount = 99999, from = 'dot' } },
            { expiresAt = os.time() - 5 }, { csEligible = 'yes' }, { source = { type = 'bad type!' } },
        }
        for i, b in ipairs(bad) do
            local res = WorkOrders.Create(spec(b))
            assert_eq(res.error, 'bad_args', 'case ' .. i)
        end
        assert_eq(WorkOrders.Create(spec(), { key = 'bad key!' }).error, 'bad_args')
        assert_eq(#logged('INSERT IGNORE INTO pf_gov_work_orders'), 0)
        assert_true(WorkOrders.Create(spec()).ok)
        assert_eq(#logged('INSERT IGNORE INTO pf_gov_work_orders'), 1)
    end)
    it('claims and reports check their arguments before anything else', function()
        assert_eq(WorkOrders.Claim('x', { kind = 'cs', cid = 'CSV1' }).error, 'bad_args')
        assert_eq(WorkOrders.Claim(1, { kind = 'boss', cid = 'CSV1' }).error, 'bad_args')
        assert_eq(WorkOrders.Claim(1, { kind = 'cs', cid = "x' OR 1=1" }).error, 'bad_args')
        assert_eq(WorkOrders.Report(1, { src = 'me' }).error, 'bad_args')
        assert_eq(WorkOrders.Report(1, nil).error, 'bad_args')
        assert_eq(WorkOrders.Report(1, { src = CS }, { key = 'bad key!' }).error, 'bad_args')
        assert_eq(WorkOrders.List({ limit = 51 }).error, 'bad_args')
        assert_eq(WorkOrders.List({ kinds = { 'arson' } }).error, 'bad_args')
        assert_eq(#logged('pf_gov_work'), 0)
    end)
end)

describe('server-position proof', function()
    it('on foot inside the site radius only; positions come from the server', function()
        Mock.coords[CS] = vector3(SITE.x + 10.0, SITE.y, SITE.z)
        assert_true((WorkOrders.OnSite(CS, SITE)))
        Mock.coords[FAR] = vector3(SITE.x + 60.0, SITE.y, SITE.z)
        assert_eq(select(2, WorkOrders.OnSite(FAR, SITE)), 'too_far')
        Mock.coords[CAR] = vector3(SITE.x, SITE.y, SITE.z)
        Mock.vehicleOf[CAR] = 55
        assert_eq(select(2, WorkOrders.OnSite(CAR, SITE)), 'vehicle')
        assert_eq(select(2, WorkOrders.OnSite(99, SITE)), 'offline')
        Mock.coords[CS] = vector3(SITE.x, SITE.y, SITE.z + 40.0)
        assert_eq(select(2, WorkOrders.OnSite(CS, SITE)), 'too_far', 'a roof far above is not the site')
    end)
    it('the sampler keeps an on-site stretch and breaks it when the worker leaves', function()
        WorkOrders.active[501] = { cid = 'CSV1', orderId = 1, kind = 'litter', x = SITE.x, y = SITE.y, z = SITE.z, r = SITE.r, expiresAt = 2e9 }
        Mock.coords[CS] = vector3(SITE.x, SITE.y, SITE.z)
        WorkOrders.SampleClaims(1000)
        WorkOrders.SampleClaims(1005)
        assert_eq(WorkOrders.active[501].since, 1000)
        Mock.coords[CS] = vector3(SITE.x + 300.0, SITE.y, SITE.z)
        WorkOrders.SampleClaims(1010)
        assert_eq(WorkOrders.active[501].since, nil)
        WorkOrders.active[501] = nil
    end)
end)

describe('effects', function()
    it('units split the order effect exactly', function()
        for _, c in ipairs({ { -400, 3 }, { -6, 4 }, { 10, 3 }, { -9, 2 }, { 7.77, 7 } }) do
            local total, units, sum = c[1], c[2], 0
            for n = 1, units do sum = sum + WorkOrders.UnitDelta(total, units, n) end
            assert_near(sum, total, 0.001, total .. '/' .. units)
        end
    end)
    it('ApplyDistrictWorkEffect changes the district and saves its row; the simulation continues from it', function()
        on('SELECT * FROM pf_gov_infra_district_state', function()
            return { { district_name = 'police_mrpd', priority_order = 2, road_condition = 80, pothole_density = 30, traffic_light_health = 90,
                street_light_health = 90, maintenance_backlog = 2000, power_stage = 1, dot_stage = 1, water_stage = 1, hazard_stage = 1 } }
        end)
        InitializeInfrastructure()
        local base = GetDistrictInfrastructureState('police_mrpd').pothole_density
        DB.log = {}
        local ok, value = ApplyDistrictWorkEffect('police_mrpd', 'pothole_density', -10)
        assert_true(ok)
        assert_near(value, base - 10, 0.001)
        local saves = logged('UPDATE pf_gov_infra_district_state')
        assert_eq(#saves, 1)
        assert_near(saves[1].p[5], base - 10, 0.001, 'pothole_density saved')
        assert_eq(saves[1].p[12], 'police_mrpd')
        -- the simulation drifts from the saved value (DOT healthy: -0.8 a tick), it does not restore it
        RecalculateInfrastructureState()
        assert_near(GetDistrictInfrastructureState('police_mrpd').pothole_density, base - 10.8, 0.001)
        assert_false((ApplyDistrictWorkEffect('police_mrpd', 'pothole_density', 3)))
    end)
    it('the generator follows the thresholds, one order per rule, capped per district', function()
        local made = WorkOrders.OnInfrastructureTick({
            police_mrpd = { pothole_density = 50, road_condition = 50, street_light_health = 10, traffic_light_health = 10, maintenance_backlog = 9999 },
            hospital = { pothole_density = 5, road_condition = 100, street_light_health = 100, traffic_light_health = 100, maintenance_backlog = 0 },
        })
        assert_eq(made, Config.WorkOrders.MaxOpenPerDistrict)
        local inserts = logged('INSERT IGNORE INTO pf_gov_work_orders')
        assert_eq(#inserts, Config.WorkOrders.MaxOpenPerDistrict)
        for _, e in ipairs(inserts) do
            assert_eq(e.p[2], 'police_mrpd')
            assert_eq(e.p[14], 'district')
        end
        assert_eq(inserts[1].p[15], 'police_mrpd:potholes')
        -- open orders of a rule block a second one
        DB.log = {}
        on("SELECT district, source_type, source_id, x, y FROM pf_gov_work_orders", function()
            return { { district = 'hospital', source_type = 'district', source_id = 'hospital:potholes', x = 1, y = 1 } }
        end)
        assert_eq(WorkOrders.OnInfrastructureTick({ hospital = { pothole_density = 50 } }), 0)
    end)
end)

describe('keyed budget moves (ledger answers)', function()
    it('an unclear answer is held: the same key never moves under a new ledger key', function()
        installBudgetDb()
        bank.script = function() return { ok = false, state = 'debited', error = 'state_conflict', txId = 'TXU' } end
        local key = 'pf-government:dept:police:equipment:1'
        local ok, err = SpendFromDepartmentSociety('police', 500, 'equipment', 'CID', 'Chief', 'Vests', key)
        assert_false(ok)
        assert_eq(err, 'payment_unclear')
        assert_eq(budgetRows[key].state, 'pending')
        assert_eq(#bank.calls, 1)
        assert_eq(bank.calls[1].key, key .. ':1')
        ok, err = SpendFromDepartmentSociety('police', 500, 'equipment', 'CID', 'Chief', 'Vests', key)
        assert_eq(err, 'payment_unclear')
        assert_eq(#bank.calls, 1, 'no second transfer')
    end)
    it('a clear refusal fails the attempt; the retry uses the next numbered key and books once', function()
        installBudgetDb()
        bank.script = function(k) if k:sub(-2) == ':1' then return { ok = false, state = 'failed', error = 'insufficient_funds', txId = 'TXF' } end end
        local key = 'pf-government:dept:police:equipment:2'
        local ok, err = SpendFromDepartmentSociety('police', 500, 'equipment', 'CID', 'Chief', 'Vests', key)
        assert_false(ok)
        assert_eq(err, 'insufficient_society_funds')
        assert_eq(budgetRows[key].state, 'failed')
        ok = SpendFromDepartmentSociety('police', 500, 'equipment', 'CID', 'Chief', 'Vests', key)
        assert_true(ok)
        assert_eq(bank.calls[2].key, key .. ':2')
        assert_eq(budgetRows[key].state, 'applied')
        local _, _, dup = SpendFromDepartmentSociety('police', 500, 'equipment', 'CID', 'Chief', 'Vests', key)
        assert_eq(dup, 'duplicate')
        assert_eq(#bank.calls, 2)
        assert_eq(#logged('spent_this_month = spent_this_month + ?'), 1, 'booked once')
    end)
    it('keyed funding is one transfer from the treasury account to the department society', function()
        installBudgetDb()
        local key = 'pf-government:dept:doj:funding:1'
        assert_true((AddFundsToDepartmentSociety('doj', 700, 'CID', 'Mayor', 'Courts', key)))
        assert_eq(#bank.calls, 1)
        assert_eq(bank.calls[1].from, 'society:government')
        assert_eq(bank.calls[1].to, 'society:doj')
        assert_eq(bank.calls[1].key, key .. ':1')
    end)
    it('the export carries the key through', function()
        installBudgetDb()
        local key = 'pf-government:dept:police:ops:9'
        assert_true((exports['pf-government']:SpendFromDepartmentSociety('police', 10, 'operations', 'CID', 'Chief', 'x', key)))
        assert_eq(bank.calls[1].key, key .. ':1')
        assert_true(budgetRows[key] ~= nil)
    end)
    it('without a key the old path runs (no key, no row key)', function()
        on('FROM pf_gov_department_monthly_plans WHERE department = ? AND month_key = ?', function(p)
            return { id = 1, department = p[1], linked_society_name = p[1], spent_this_month = 0 }
        end)
        assert_true((SpendFromDepartmentSociety('police', 10, 'operations', 'CID', 'Chief', 'x')))
        assert_eq(#bank.calls, 1)
        assert_eq(bank.calls[1].key, nil, 'unkeyed: pfm-banking makes its own one-off key')
        local rows = logged('INSERT INTO pf_gov_budget_transactions')
        assert_eq(#rows, 1)
        assert_true(not rows[1].q:find('idem_key', 1, true), 'the legacy row has no key')
    end)
end)

describe('CreateBill export', function()
    it('passes issuedBy, issuedByName and recurring to CreateBill', function()
        local seen
        on('INSERT IGNORE INTO pf_gov_bills', function(p) seen = p return 77 end)
        local ok, _, id = exports['pf-government']:CreateBill('citizen', 'CID9', 50, 'property_tax', nil, 'Tax', 'sys', 'City Hall', { ref = 'house:a', period = '2026-11-02' })
        assert_true(ok)
        assert_eq(id, 77)
        assert_eq(seen[7], 'sys')
        assert_eq(seen[8], 'City Hall')
        assert_eq(seen[9], 'house:a')
        assert_eq(seen[10], '2026-11-02')
    end)
end)

describe('config contract (15I and pf-justice read these)', function()
    it('corrections and doj are budget departments with their own societies', function()
        assert_eq(Config.Budgets.LinkedSocietyAccounts.corrections, 'corrections')
        assert_eq(Config.Budgets.LinkedSocietyAccounts.doj, 'doj')
        assert_true(Config.Budgets.Defaults.corrections > 0 and Config.Budgets.Defaults.doj > 0)
        assert_true(Config.Budgets.DepartmentNames.corrections ~= nil and Config.Budgets.DepartmentNames.doj ~= nil)
    end)
    it('the departments block maps jobs, implied qualifications and callers', function()
        local D = Config.Departments
        assert_eq(D.Jobs.ambulance, 'ems')
        assert_eq(D.Jobs.corrections, 'corrections')
        for job, grades in pairs(D.Implied) do
            for _, quals in pairs(grades) do
                for _, q in ipairs(quals) do assert_true(D.Qualifications[q] ~= nil, job .. ': ' .. q) end
            end
        end
        assert_true(D.Callers.GrantQualification['pf-emsmdt'])
    end)
    it('every generator rule and event rule names valid kinds, fields and paying departments', function()
        local W = Config.WorkOrders
        local fields = { pothole_density = true, road_condition = true, street_light_health = true, traffic_light_health = true, maintenance_backlog = true }
        for _, r in ipairs(W.Thresholds) do
            assert_true(fields[r.field], r.id)
            for _, k in ipairs(r.kinds) do assert_true(W.MinUnitSeconds[k] ~= nil, k) end
            assert_true(Config.Budgets.LinkedSocietyAccounts[r.pay.from] ~= nil, r.id)
        end
        for kind, r in pairs(W.FromEvents) do assert_true(W.MinUnitSeconds[r.kind] ~= nil, kind) end
        for d, sites in pairs(W.Sites) do
            assert_true(Config.Infrastructure.Districts[d] ~= nil, d)
            for _, s in ipairs(sites) do assert_true(s.r <= W.MaxRadius, s.label) end
        end
    end)
end)
