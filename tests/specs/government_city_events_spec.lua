-- pf-government decisions on the city timeline (mocked): each real change emits its pf-services
-- event once, with the public fields the news presets read; a change to the same value, a failed
-- change or a repeat emits nothing; citizen ids stay in `actor`, never in the data.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pf-services'] = true, ['pf-government'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
vec4 = vec4 or vector4
GlobalState = {}

local DB = { handlers = {}, nextId = 100 }
local function on(fragment, fn) table.insert(DB.handlers, 1, { fragment, fn }) end
-- rows come back as copies, as from a real database (a later UPDATE must not change a row read before)
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = type(x) == 'table' and copy(x) or x end
    return out
end
local function run(kind, q, p)
    for _, h in ipairs(DB.handlers) do if q:find(h[1], 1, true) then return copy(h[2](p or {}, kind)) end end
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

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/taxes.lua', 'server/budgets.lua', 'server/laws.lua', 'server/licenses.lua',
    'server/utilities.lua', 'server/bills.lua', 'server/businesses.lua', 'server/staff.lua', 'server/callbacks.lua',
    'server/loans.lua', 'server/infrastructure.lua', 'server/integrations.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function LogAudit() end
function NotifyGovernment() end
function DebugPrint() end
function IsGovernmentEmployee(src) local P = Mock.players[src] return P ~= nil and P.PlayerData.job.name == 'government' end
function WithdrawFromTreasury() return true end
GovSchema.Ensure = function() return true end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']

local events = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) events[#events + 1] = { kind = kind, data = data, opts = opts or {} } return #events end,
}
local function emitted(kind)
    local out = {}
    for _, e in ipairs(events) do if e.kind == kind then out[#out + 1] = e end end
    return out
end
local function nui(src, action, data)
    local got
    data = data or {}
    data.source = src
    Government.NuiCallbacks[action](data, function(r) got = r end)
    return got
end

local MAYOR = 1
local BIZ = { business_id = 'store:corner', business_name = 'Corner Store', business_type = 'store', owner_id = 'OWN1', owner_name = 'Olive Owner', district = 'downtown' }
local all = {}   -- every event of the spec, checked for leaked citizen ids at the end

BeforeEach = function()
    for _, e in ipairs(events) do all[#all + 1] = e end
    events = {}
    Mock.reset()
    DB.handlers = {}
    on('SELECT * FROM pf_gov_businesses WHERE business_id = ?', function(p) if p[1] == BIZ.business_id then return BIZ end end)
    on('SELECT id FROM pf_gov_businesses WHERE business_id = ?', function(p) if p[1] == BIZ.business_id then return { id = 1 } end end)
    Mock.players = {}
    local p = Mock.newPlayer(MAYOR, 'MAY1')
    p.PlayerData.job = { name = 'government', grade = { level = 4 }, onduty = true }
    p.PlayerData.charinfo = { firstname = 'Maya', lastname = 'Mayor' }
end

describe('taxes', function()
    local tax
    local function taxes()
        tax = { rate = 8.5, min_rate = 0, max_rate = 50, enabled = 1, description = 'Sales tax on transactions' }
        on('FROM pf_gov_taxes WHERE tax_type = ?', function() return tax end)
    end
    it('a rate change emits once with the old and new rate; the same rate again emits nothing', function()
        taxes()
        assert_true(SetTaxRate('sales', 9.5, 'MAY1', 'Maya Mayor'))
        local ev = emitted('gov.tax.changed')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.tax, 'sales')
        assert_eq(ev[1].data.label, 'Sales tax')
        assert_eq(ev[1].data.oldRate, 8.5)
        assert_eq(ev[1].data.newRate, 9.5)
        assert_eq(ev[1].data.direction, 'up')
        assert_eq(ev[1].opts.actor, 'MAY1')
        assert_true(ev[1].opts.title:find('rises') ~= nil)
        assert_true(SetTaxRate('sales', 9.5, 'MAY1', 'Maya Mayor'))
        assert_eq(#emitted('gov.tax.changed'), 1, 'no-op')
    end)
    it('a change the database refused emits nothing', function()
        on('UPDATE pf_gov_taxes SET rate', function() return 0 end)
        assert_false(SetTaxRate('sales', 12, 'MAY1', 'Maya Mayor'))
        assert_eq(#events, 0)
    end)
    it('switching a tax off and on emits once per real switch', function()
        assert_true(SetTaxEnabled('sales', false, 'MAY1', 'Maya Mayor'))
        assert_true(SetTaxEnabled('sales', false, 'MAY1', 'Maya Mayor'))
        assert_true(SetTaxEnabled('sales', true, 'MAY1', 'Maya Mayor'))
        local ev = emitted('gov.tax.toggled')
        assert_eq(#ev, 2)
        assert_eq(ev[1].data.enabled, false)
        assert_eq(ev[2].data.enabled, true)
        assert_eq(ev[1].data.label, 'Sales tax')
    end)
end)

describe('budgets', function()
    it('a department budget change emits old and new; the same budget emits nothing', function()
        local budget = 200000
        on('SELECT * FROM pf_gov_department_monthly_plans WHERE department = ? AND month_key = ?', function()
            return { id = 1, department = 'police', month_key = '2026-10', approved_monthly_budget = budget, linked_society_name = 'police', spent_this_month = 0 }
        end)
        on('UPDATE pf_gov_department_monthly_plans SET approved_monthly_budget', function(p) budget = p[1] return 1 end)
        assert_true(SetBudget('police', 250000, 'MAY1', 'Maya Mayor'))
        assert_true(SetBudget('police', 250000, 'MAY1', 'Maya Mayor'))
        local ev = emitted('gov.budget.changed')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.label, 'Police Department')
        assert_eq(ev[1].data.oldBudget, 200000)
        assert_eq(ev[1].data.newBudget, 250000)
        assert_eq(ev[1].data.change, 50000)
    end)
end)

describe('laws', function()
    it('publishing a draft and repealing a law in force emit once; repeats and drafts do not', function()
        local laws = {
            [1] = { id = 1, title = 'Noise Ordinance', category = 'Public Order', content = 'No loud music after <b>midnight</b>.', status = 'draft', fine_min = 100, fine_max = 500, penalty_min = 0, penalty_max = 0 },
            [2] = { id = 2, title = 'Draft Rule', category = 'Other', content = 'x', status = 'draft' },
        }
        on('FROM pf_gov_laws WHERE id = ? LIMIT 1', function(p) return laws[tonumber(p[1])] end)
        on('UPDATE pf_gov_laws SET status = ?, effective_date', function(p) laws[p[2]].status = p[1] return 1 end)
        on('UPDATE pf_gov_laws SET status = ?, repealed_by', function(p) laws[p[3]].status = p[1] return 1 end)
        assert_true(PublishLaw(1, 'MAY1', 'Maya Mayor'))
        assert_true(PublishLaw(1, 'MAY1', 'Maya Mayor'))
        local pub = emitted('gov.law.published')
        assert_eq(#pub, 1)
        assert_eq(pub[1].data.title, 'Noise Ordinance')
        assert_eq(pub[1].data.category, 'Public Order')
        assert_eq(pub[1].data.summary, 'No loud music after midnight .')
        assert_eq(pub[1].data.fineMax, 500)
        assert_true(RepealLaw(1, 'MAY1', 'Maya Mayor'))
        assert_true(RepealLaw(1, 'MAY1', 'Maya Mayor'))
        assert_true(RepealLaw(2, 'MAY1', 'Maya Mayor'))
        local rep = emitted('gov.law.repealed')
        assert_eq(#rep, 1)
        assert_eq(rep[1].data.lawId, 1)
    end)
end)

describe('utilities and infrastructure', function()
    it('cutting off a business emits the services that really went off', function()
        local util = { power_status = 'active', water_status = 'active', property_name = 'Corner Store' }
        on('SELECT power_status, water_status, property_name FROM pf_gov_utilities', function() return util end)
        on('UPDATE pf_gov_utilities SET power_status = ?, water_status = ?', function() util.power_status, util.water_status = 'disconnected', 'disconnected' return 1 end)
        on('UPDATE pf_gov_utilities SET power_status = ?, disconnected_by', function() util.power_status = 'disconnected' return 1 end)
        DisconnectService('business', 'store:corner', 'power', 'MAY1', 'Maya Mayor', 'Unpaid bills')
        DisconnectService('business', 'store:corner', 'power', 'system', 'System', 'Delinquent bill #3')
        DisconnectService('business', 'store:corner', 'both', 'system', 'System', 'Delinquent bill #3')
        DisconnectService('property', 'house1', 'power', 'system', 'System', 'x')
        local ev = emitted('gov.utility.disconnected')
        assert_eq(#ev, 2)
        assert_eq(ev[1].data.business, 'Corner Store')
        assert_eq(ev[1].data.utility, 'power')
        assert_eq(ev[1].data.reason, 'Unpaid bills')
        assert_eq(ev[1].opts.district, 'downtown')
        assert_eq(ev[2].data.utility, 'water', 'power was already off')
        assert_eq(ev[2].opts.actor, nil, 'the system is not a citizen')
    end)
    it('district power and water: cut and restored once per crossing', function()
        local balance = { power = 0, water = 0, dot = 1e9 }
        function GetDepartmentMonthlyBudgetSnapshot(dep) return { approved_monthly_budget = 100000, society_balance = balance[dep] or 1e9, spent_this_month = 0, projected_month_end_balance = 0 } end
        on('SELECT * FROM pf_gov_infra_department_state', function()
            return {
                { department = 'power', condition_percent = 100, district_impact_stage = 1, linked_society_name = 'power', installed_upgrades = '{}' },
                { department = 'water', condition_percent = 100, district_impact_stage = 1, linked_society_name = 'water', installed_upgrades = '{}' },
                { department = 'dot', condition_percent = 100, district_impact_stage = 1, linked_society_name = 'dot', installed_upgrades = '{}' },
            }
        end)
        on('SELECT * FROM pf_gov_infra_district_state', function()
            return { { district_name = 'downtown', priority_order = 3, power_stage = 1, water_stage = 1, dot_stage = 1, road_condition = 100, traffic_light_health = 100, street_light_health = 100 } }
        end)
        InitializeInfrastructure()
        local cut, wcut = emitted('gov.power.cut'), emitted('gov.water.cut')
        assert_eq(#cut, 1)
        assert_eq(cut[1].data.district, 'downtown')
        assert_eq(cut[1].data.label, 'Downtown')
        assert_eq(cut[1].opts.district, 'downtown')
        assert_eq(#wcut, 1)
        RecalculateInfrastructureState()
        assert_eq(#emitted('gov.power.cut'), 1, 'still cut: no new event')
        balance.power, balance.water = 1e9, 1e9
        RecalculateInfrastructureState()
        assert_eq(#emitted('gov.power.restored'), 1)
        assert_eq(#emitted('gov.water.restored'), 1)
        RecalculateInfrastructureState()
        assert_eq(#emitted('gov.power.restored'), 1)
        -- an upgrade is bought once
        assert_true(PurchaseDepartmentUpgrade('power', 'transformer_redundancy', 'MAY1', 'Maya Mayor'))
        assert_false(PurchaseDepartmentUpgrade('power', 'transformer_redundancy', 'MAY1', 'Maya Mayor'))
        local up = emitted('gov.infra.upgrade')
        assert_eq(#up, 1)
        assert_eq(up[1].data.upgrade, 'Transformer Redundancy')
        assert_eq(up[1].data.departmentLabel, 'Power Department')
        assert_eq(up[1].data.cost, 90000)
    end)
end)

describe('the business registry', function()
    it('registering a new business emits; updating a known one does not', function()
        assert_true(RegisterBusiness('store:new', 'New Shop', 'store', 'CID9', 'Nina New'))
        on('SELECT * FROM pf_gov_businesses WHERE business_id = ?', function() return { BIZ } end)
        assert_true(RegisterBusiness('store:corner', 'Corner Store', 'store', 'OWN1', 'Olive Owner'))
        local ev = emitted('gov.business.registered')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.business, 'New Shop')
        assert_eq(ev[1].data.owner, 'Nina New')
    end)
    it('closing and reopening emit once per real change', function()
        local status = 'active'
        on('SELECT COALESCE(business_status', function() return status end)
        on('UPDATE pf_gov_businesses SET business_status = ?, closed_at', function(p) status = p[1] return 1 end)
        assert_true(nui(MAYOR, 'business:setStatus', { businessId = 'store:corner', status = 'closed', reason = 'Health hazard' }).ok)
        assert_true(nui(MAYOR, 'business:setStatus', { businessId = 'store:corner', status = 'closed' }).ok)
        assert_true(nui(MAYOR, 'business:setStatus', { businessId = 'store:corner', status = 'active' }).ok)
        local closed, reopened = emitted('gov.business.closed'), emitted('gov.business.reopened')
        assert_eq(#closed, 1)
        assert_eq(closed[1].data.reason, 'Health hazard')
        assert_eq(closed[1].data.business, 'Corner Store')
        assert_eq(closed[1].opts.actor, 'MAY1')
        assert_eq(#reopened, 1)
    end)
    it('a transfer emits the new owner\'s name, not their citizen id; the same owner emits nothing', function()
        local owner = { id = 1, owner_id = 'OWN1', owner_name = 'Olive Owner' }
        on('SELECT id, owner_id, owner_name FROM pf_gov_businesses', function() return owner end)
        on('SELECT 1 FROM players', function() return 1 end)
        on('UPDATE pf_gov_businesses SET owner_id = ?', function(p) owner.owner_id, owner.owner_name = p[1], p[2] return 1 end)
        assert_true(TransferBusinessOwnership('other:corner', 'CID9', 'Nina New', 'MAY1'))
        assert_true(TransferBusinessOwnership('other:corner', 'CID9', 'Nina New', 'MAY1'))
        local ev = emitted('gov.business.transferred')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.newOwner, 'Nina New')
        assert_eq(ev[1].data.previousOwner, 'Olive Owner')
    end)
    it('inspections: a failure is news, a pass is recorded as passed', function()
        assert_true(RecordBusinessInspection('store:corner', 'non_compliant', 'Expired food on shelves', 'MAY1', 'Maya Mayor'))
        assert_true(RecordBusinessInspection('store:corner', 'compliant', '', 'MAY1', 'Maya Mayor'))
        assert_false(RecordBusinessInspection('store:corner', 'closed', ''))
        local failed, passed = emitted('gov.inspection.failed'), emitted('gov.inspection.passed')
        assert_eq(#failed, 1)
        assert_eq(failed[1].data.business, 'Corner Store')
        assert_eq(failed[1].data.findings, 'Expired food on shelves')
        assert_eq(failed[1].data.inspector, 'Maya Mayor')
        assert_eq(#passed, 1)
        assert_eq(passed[1].data.passed, true)
    end)
    it('a defaulted loan emits once, and closes the business only if it was open', function()
        Config.Loans.CloseBusinessOnDefault = true
        local loan = { id = 4, business_id = 'store:corner', remaining_amount = 1000, principal_amount = 1000, interest_rate = 0, amount_due = 0, missed_payments = 2, auto_pay = 0, due_ts = 1 }
        assert_eq(Loans.ProcessDue(loan), 'defaulted')
        local ev = emitted('gov.loan.defaulted')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.business, 'Corner Store')
        assert_eq(ev[1].data.missedPayments, 3)
        assert_eq(#emitted('gov.business.closed'), 1)
        on("WHERE business_id = ? AND COALESCE(business_status, 'active') <> 'closed'", function() return 0 end)
        loan.missed_payments = 2
        Loans.ProcessDue(loan)
        assert_eq(#emitted('gov.business.closed'), 1, 'already closed')
        Config.Loans.CloseBusinessOnDefault = false
    end)
end)

describe('announcements, staff and licenses', function()
    it('an announcement reaches the timeline with an excerpt', function()
        local res = nui(MAYOR, 'announcement:create', { title = 'Road works', content = 'Vinewood Boulevard is closed all week.', priority = 'high' })
        assert_true(res.ok)
        local ev = emitted('gov.announcement')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.title, 'Road works')
        assert_eq(ev[1].data.priority, 'high')
        assert_eq(ev[1].data.excerpt, 'Vinewood Boulevard is closed all week.')
        assert_eq(ev[1].data.author, 'Maya Mayor')
    end)
    it('appointments emit the role; a role set to the same role emits nothing', function()
        assert_true(AddStaffMember('CID5', 'Tom Treasurer', 'Treasurer', 'MAY1', 'Maya Mayor'))
        on('SELECT name, role FROM pf_gov_staff', function() return { name = 'Tom Treasurer', role = 'Treasurer' } end)
        assert_true(UpdateStaffRole('CID5', 'Treasurer', 'MAY1', 'Maya Mayor'))
        assert_true(UpdateStaffRole('CID5', 'Deputy Mayor', 'MAY1', 'Maya Mayor'))
        local ev = emitted('gov.staff.appointed')
        assert_eq(#ev, 2)
        assert_eq(ev[1].data.role, 'Treasurer')
        assert_eq(ev[1].data.name, 'Tom Treasurer')
        assert_eq(ev[2].data.role, 'Deputy Mayor')
        assert_eq(ev[2].data.previousRole, 'Treasurer')
    end)
    it('revoking a license emits once', function()
        local lic = { id = 5, license_type = 'restaurant', owner_type = 'business', owner_id = 'store:corner', owner_name = 'Corner Store', status = 'active' }
        on('FROM pf_gov_licenses WHERE id = ? LIMIT 1', function() return lic end)
        on('UPDATE pf_gov_licenses SET status = ?, notes = ?', function(p) lic.status = p[1] return 1 end)
        assert_true(RevokeLicense(5, 'MAY1', 'Maya Mayor', 'Repeated violations'))
        assert_true(RevokeLicense(5, 'MAY1', 'Maya Mayor', 'Again'))
        assert_true(SuspendLicense(5, 'MAY1', 'Maya Mayor', 'x'))
        local ev = emitted('gov.license.revoked')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.label, 'Restaurant License')
        assert_eq(ev[1].data.holder, 'Corner Store')
        assert_eq(ev[1].data.reason, 'Repeated violations')
    end)
    it('no event of this spec carries a citizen id in its public data', function()
        for _, e in ipairs(events) do all[#all + 1] = e end
        assert_true(#all > 15, 'events were checked')
        local function scan(v, kind)
            if type(v) == 'table' then for _, x in pairs(v) do scan(x, kind) end
            elseif type(v) == 'string' then
                for _, cid in ipairs({ 'MAY1', 'OWN1', 'CID9', 'CID5' }) do assert_true(v ~= cid, kind .. ' leaks ' .. cid) end
            end
        end
        for _, e in ipairs(all) do scan(e.data, e.kind) end
    end)
end)

describe('without pf-services', function()
    it('decisions work and nothing is emitted', function()
        started['pf-services'] = nil
        on('FROM pf_gov_taxes WHERE tax_type = ?', function() return { rate = 1, min_rate = 0, max_rate = 50, enabled = 1 } end)
        assert_true(SetTaxRate('business', 3, 'MAY1', 'Maya Mayor'))
        assert_eq(#events, 0)
        started['pf-services'] = true
    end)
end)
