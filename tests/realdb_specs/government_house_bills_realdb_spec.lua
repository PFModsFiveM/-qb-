-- pf-government bills on a real database, with the real pfm-houses export, the real ledger and the
-- real pf-citizen Bills app:
--   late fees: an overdue bill gets its fee once (or once per configured period, up to the configured
--   count), always a share of the original amount, never again on a rerun, a restart or a run racing
--   another one; property tax bills follow the same rule;
--   house utilities: billed to the house's current owner as a citizen bill (pf_gov_bills has no
--   'property' payer), once per house and cycle, shown and paid in the owner's Bills app; a delinquent
--   bill cuts that house's power while the same citizen owns it, paying restores it, and the cut does
--   not pass to the next owner; old bills stored without a payer are closed by migration 3;
--   the Fines app lists citizens' house bills (property tax, utilities) so staff can see and waive them.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
GetInvokingResource = GetInvokingResource or function() return nil end
local states = { ['pfm-cityhall'] = 'missing', ['pfm-phone'] = 'missing', ['pf-services'] = 'missing', ['pfm-apartments'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
CancelEvent = CancelEvent or function() end

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
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
    Push = function() return true end, PushToJob = function() return 0 end, PushToCitizen = function() return true end,
}

-- pfm-houses: listings and owners in its own tables, read only through its export
RealDB.exec('pfm-houses/qb-houses.sql')
MySQL.query.await('CREATE TABLE IF NOT EXISTS inventories (identifier VARCHAR(100) PRIMARY KEY, items LONGTEXT)')
local COORDS = '{"enter":{"x":100.0,"y":200.0,"z":30.0,"h":0.0},"cam":{"x":100.0,"y":200.0,"z":30.0,"h":0.0,"yaw":-10.0}}'
local function listing(name, label, price)
    MySQL.insert.await("INSERT INTO houselocations (name, label, coords, owned, price, tier, garage) VALUES (?, ?, ?, 1, ?, 1, '{}')",
        { name, label, COORDS, price })
end
local function own(house, cid, paid)
    MySQL.insert.await('INSERT INTO player_houses (house, identifier, citizenid, keyholders) VALUES (?, ?, ?, ?)',
        { house, 'license:' .. cid, cid, json.encode({ cid }) })
    if paid then MySQL.update.await('UPDATE player_houses SET purchase_price = ? WHERE house = ? ORDER BY id DESC LIMIT 1', { paid, house }) end
end
listing('vinewood1', '1 Vinewood Hills', 300000)
listing('grove7', '7 Grove Street', 120000)

local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
Citizen.CreateThread = CreateThread
QBCoreMock.Commands.Add = function() end
function GetCurrentResourceName() return 'pfm-houses' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-houses/config.lua')
load_resource('pfm-houses/server/main.lua')
load_resource('pfm-houses/server/apps.lua')
PFHouses.Start()
assert(PFHouses.dbReady, 'pfm-houses migrations')
threads[1]()
local housesConfig = Config
own('vinewood1', 'OWNA', 250000)
own('grove7', 'OWNB')
Mock.exportsByResource['pfm-houses'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/taxes.lua',
    'server/utilities.lua', 'server/bills.lua', 'server/property_tax.lua', 'server/businesses.lua', 'server/audit.lua',
    'server/licenses.lua', 'server/integrations.lua', 'server/staff.lua', 'server/callbacks.lua',
    'server/apps/common.lua', 'server/apps/fines.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
Config.Houses = housesConfig.Houses
function NotifyGovernment() end
function IsGovernmentEmployee() return false end
function DebugPrint() end
local govX = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-government'] = govX
load_resource('tests/lua/gov_registry_exports.lua')
Mock.exportsByResource['__self'] = nil
assert(GovSchema.Ensure(), 'government migrations')
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()
govX.ManagesBusiness = function() return false end
govX.GetBusinessEmployees = function() return { ok = true, employees = {} } end

-- pf-citizen (the Bills app)
function GetCurrentResourceName() return 'pf-citizen' end
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
assert(PFCitizen.Start(), 'pf-citizen start')
function GetCurrentResourceName() return 'pf-government' end
local Bills = PFCitizen.Bills

local DAY = 86400
local T0 = 1793793600                 -- Wednesday 2026-11-04 12:00 UTC
local CLERK = 9

local function bill(id) return MySQL.single.await('SELECT * FROM pf_gov_bills WHERE id = ?', { id }) end
local function num(v) return tonumber(v) or 0 end
local function newBill(cid, amount, dueAt, billType)
    local ok, _, id = CreateBill('citizen', cid, amount, billType or 'fine', os.date('%Y-%m-%d %H:%M:%S', dueAt), 'Test bill', 'GOV1', 'Officer')
    assert(ok, 'bill created')
    return id
end
local function withBillsConfig(changes, fn)
    local saved = {}
    for k, v in pairs(changes) do saved[k] = Config.Bills[k]; Config.Bills[k] = v end
    local ok, err = pcall(fn)
    for k, v in pairs(saved) do Config.Bills[k] = v end
    assert(ok, err)
end
local function houseUtilityBills(house, where, params)
    local p = { 'utility:property:' .. house }
    for _, v in ipairs(params or {}) do p[#p + 1] = v end
    return MySQL.query.await('SELECT * FROM pf_gov_bills WHERE bill_ref = ? ' .. (where or '') .. ' ORDER BY id', p) or {}
end
local function utility(house) return MySQL.single.await("SELECT * FROM pf_gov_utilities WHERE property_type = 'property' AND property_id = ?", { house }) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    PFCitizen.__resetLimits()
    Mock.clock = T0
    states['pfm-houses'] = nil
    PFHouses.dbReady = true
end

describe('late fees', function()
    it('have their columns (migration 3, safe to run again)', function()
        for _, c in ipairs({ 'late_fee_count', 'late_fee_amount', 'last_late_fee_at' }) do assert_true(MigrationColumnExists('pf_gov_bills', c), c) end
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 3")
        GovSchema.__reset()
        assert_true(GovSchema.Ensure(), 'rerun')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 3")), 1)
    end)
    it('an overdue bill gets the fee once, however often and however long after the run goes', function()
        local id = newBill('FEE1', 200, T0 + 3 * DAY)
        Mock.clock = T0 + 3 * DAY + 3600                  -- an hour late: not a whole interval yet
        assert_eq(ProcessBillLateFees().applied, 0)
        assert_eq(num(bill(id).amount), 200)
        Mock.clock = T0 + 4 * DAY + 60                    -- a day late
        local res = ProcessBillLateFees()
        assert_eq(res.applied, 1, 'the late fee path is dead')
        local b = bill(id)
        assert_eq(num(b.amount), 220, '10% of 200')
        assert_eq(num(b.late_fee_amount), 20)
        assert_eq(num(b.late_fee_count), 1)
        -- every hour after, for a month, and after a restart (fresh module state): no more fees
        for h = 1, 30 do
            Mock.clock = T0 + 4 * DAY + h * DAY
            ProcessBillLateFees()
        end
        ProcessBillLateFees = nil
        load_resource('[pfscripts]/pf-government/server/bills.lua')
        Mock.clock = T0 + 60 * DAY
        assert_eq(ProcessBillLateFees().applied, 0)
        assert_eq(num(bill(id).amount), 220, 'compounded')
        assert_eq(num(bill(id).late_fee_count), 1)
    end)
    it('once per period up to the configured count, each a share of the original amount', function()
        withBillsConfig({ LateFeeMaxCount = 3 }, function()
            local id = newBill('FEE2', 100, T0)
            Mock.clock = T0 + DAY + 1
            ProcessBillLateFees()
            ProcessBillLateFees()
            assert_eq(num(bill(id).amount), 110)
            Mock.clock = T0 + 2 * DAY + 1
            ProcessBillLateFees()
            assert_eq(num(bill(id).amount), 120, 'the second fee is 10% of 100, not of 110')
            Mock.clock = T0 + 10 * DAY
            ProcessBillLateFees()
            ProcessBillLateFees()
            assert_eq(num(bill(id).amount), 130, 'at most three fees')
            assert_eq(num(bill(id).late_fee_count), 3)
        end)
    end)
    it('two runs reading the same bill add one fee', function()
        local id = newBill('FEE3', 500, T0)
        Mock.clock = T0 + 2 * DAY
        -- another server thread applies the fee between this run's read and its update
        local query = MySQL.query.await
        MySQL.query.await = function(q, p)
            local out = query(q, p)
            if q:find('TIMESTAMPADD', 1, true) then
                MySQL.query.await = query
                MySQL.update.await('UPDATE pf_gov_bills SET amount = amount + 50, late_fee_amount = late_fee_amount + 50, late_fee_count = late_fee_count + 1 WHERE id = ?', { id })
            end
            return out
        end
        ProcessBillLateFees()
        MySQL.query.await = query
        assert_eq(num(bill(id).amount), 550)
        assert_eq(num(bill(id).late_fee_count), 1)
    end)
    it('paid, waived and undated bills get none; a disabled fee adds nothing', function()
        local paid = newBill('FEE4', 100, T0)
        assert_true(PayBill(paid, 100, 'FEE4', 'Payer'))
        local waived = newBill('FEE4', 100, T0)
        assert_true(WaiveBill(waived, 'GOV1', 'Clerk', 'mistake'))
        local undated = select(3, CreateBill('citizen', 'FEE4', 100, 'fine', nil, 'x', 'GOV1', 'Officer'))
        MySQL.update.await('UPDATE pf_gov_bills SET due_date = NULL WHERE id = ?', { undated })
        local open = newBill('FEE4', 100, T0)
        Mock.clock = T0 + 5 * DAY
        withBillsConfig({ LateFeeEnabled = false }, function() assert_eq(ProcessBillLateFees().off, 'disabled') end)
        assert_eq(num(bill(open).amount), 100)
        ProcessBillLateFees()
        assert_eq(num(bill(paid).amount), 100)
        assert_eq(num(bill(waived).amount), 100)
        assert_eq(num(bill(undated).amount), 100)
        assert_eq(num(bill(open).amount), 110)
    end)
    it('a property tax bill follows the same rule and is paid with its fee in the Bills app', function()
        local res = PropertyTax.Run(T0)
        assert_eq(res.billed, 2)
        local tax = MySQL.single.await("SELECT * FROM pf_gov_bills WHERE bill_ref = 'house:vinewood1' AND bill_period = ?", { res.period })
        assert_eq(num(tax.amount), 1250)
        Mock.clock = T0 + 8 * DAY + 1                     -- due in 7 days, then a day late
        ProcessBillLateFees()
        Mock.clock = T0 + 9 * DAY
        ProcessBillLateFees()
        assert_eq(num(bill(tax.id).amount), 1375, 'once, 10% of 1,250')
        local P = Mock.newPlayer(1, 'OWNA')
        P.PlayerData.money = { cash = 0, bank = 5000 }
        local shown
        for _, b in ipairs(Bills.List(1).open) do if b.key == 'gov:' .. tax.id then shown = b end end
        assert_eq(shown.remaining, 1375)
        assert_true(Bills.Pay(1, { key = 'gov:' .. tax.id }).ok)
        assert_eq(P.PlayerData.money.bank, 5000 - 1375)
        assert_eq(bill(tax.id).status, 'paid')
    end)
end)

describe('house utilities', function()
    local cycle = function(t) return UtilityPeriod(t) end
    it('are billed to the owner as a citizen bill, once per house and cycle', function()
        assert_true(exports['pf-government']:RegisterProperty('vinewood1', '1 Vinewood Hills', 'OWNA', 'Ann Owner'))
        assert_true(exports['pf-government']:RegisterProperty('grove7', '7 Grove Street', 'OWNB', 'Bob Owner'))
        local res = ProcessUtilityBilling(T0)
        assert_eq(res.houses, nil, tostring(res.houses))
        local due = Config.Utilities.PowerBillAmount + Config.Utilities.WaterBillAmount
        local list = houseUtilityBills('vinewood1')
        assert_eq(#list, 1, 'the house bill failed to insert')
        assert_eq(list[1].target_type, 'citizen')
        assert_eq(list[1].target_id, 'OWNA')
        assert_eq(list[1].bill_type, 'utility')
        assert_eq(num(list[1].amount), due)
        assert_eq(list[1].bill_period, cycle(T0))
        assert_true(tostring(list[1].description):find('1 Vinewood Hills', 1, true) ~= nil, tostring(list[1].description))
        assert_eq(houseUtilityBills('grove7')[1].target_id, 'OWNB')
        -- the same cycle again (a restart, a retry): nothing new; the next cycle: one more
        ProcessUtilityBilling(T0 + 3600)
        ProcessUtilityBilling(T0 + 7200, { housesOnly = true, period = cycle(T0) })
        assert_eq(#houseUtilityBills('vinewood1'), 1)
        ProcessUtilityBilling(T0 + DAY)
        assert_eq(#houseUtilityBills('vinewood1'), 2)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_bills WHERE target_type NOT IN ('citizen', 'business')")), 0)
    end)
    it("show in the owner's Bills app and are paid there", function()
        local P = Mock.newPlayer(1, 'OWNA')
        P.PlayerData.money = { cash = 0, bank = 1000 }
        local b = houseUtilityBills('vinewood1')[1]
        local shown
        for _, v in ipairs(Bills.List(1).open) do if v.key == 'gov:' .. b.id then shown = v end end
        assert_true(shown ~= nil, 'not listed for the owner')
        assert_eq(shown.kind, 'Utilities')
        assert_true(shown.canPay)
        assert_true(Bills.Pay(1, { key = 'gov:' .. b.id }).ok)
        assert_eq(bill(b.id).status, 'paid')
        assert_eq(P.PlayerData.money.bank, 1000 - num(b.amount))
        Mock.newPlayer(2, 'OWNB')
        for _, v in ipairs(Bills.List(2).open) do assert_true(v.key ~= 'gov:' .. b.id, 'listed for another citizen') end
    end)
    it('a delinquent bill cuts that house\'s power; paying the owner\'s delinquent bills restores it', function()
        MySQL.query.await("DELETE FROM pf_gov_bills WHERE bill_ref LIKE 'utility:property:%'")
        local T = T0 + 30 * DAY
        ProcessUtilityBilling(T)
        local b = houseUtilityBills('vinewood1')[1]
        Mock.clock = T + 15 * DAY                         -- due + the escalation days
        ProcessBillEscalation()
        assert_eq(bill(b.id).status, 'delinquent')
        assert_false(HasPower('property', 'vinewood1'), 'the house kept its power')
        assert_true(HasPower('property', 'grove7') == false, 'grove7 is delinquent too')
        assert_true(PayBill(b.id, num(bill(b.id).amount), 'OWNA', 'Ann'))
        assert_true(HasPower('property', 'vinewood1'), 'paid, the power came back')
    end)
    it('a cut-off made for the previous owner does not pass to the next owner, nor do the bills', function()
        -- grove7 is cut for OWNB's delinquent bill; OWNB sells it to BUYR (pfm-houses registers the sale)
        assert_false(HasPower('property', 'grove7'))
        local old = houseUtilityBills('grove7', "AND status = 'delinquent'")[1]
        MySQL.update.await("UPDATE player_houses SET citizenid = 'BUYR' WHERE house = 'grove7'")
        assert_true(exports['pf-government']:RegisterProperty('grove7', '7 Grove Street', 'BUYR', 'Buyer'))
        assert_true(HasPower('property', 'grove7'), 'the buyer has no power for the seller\'s debt')
        assert_eq(bill(old.id).target_id, 'OWNB', 'the seller keeps their bill')
        ProcessUtilityBilling(T0 + 50 * DAY)
        local latest = houseUtilityBills('grove7')
        assert_eq(latest[#latest].target_id, 'BUYR')
        -- the seller's late payment does not touch the buyer's house
        DisconnectService('property', 'grove7', 'power', 'GOV1', 'Inspector', 'Safety')
        assert_true(PayBill(old.id, num(old.amount), 'OWNB', 'Bob'))
        assert_false(HasPower('property', 'grove7'), 'a staff cut-off was lifted')
        RestoreService('property', 'grove7', 'both', 'GOV1', 'Inspector')
    end)
    it('follow the owner pfm-houses reports, even when it was not registered: a house nobody owns is not billed', function()
        -- sold without RegisterProperty (as pfm-houses' transfer does), and grove7 handed back to the state
        MySQL.update.await("UPDATE player_houses SET citizenid = 'NEWA' WHERE house = 'vinewood1'")
        MySQL.query.await("DELETE FROM player_houses WHERE house = 'grove7'")
        local T = T0 + 60 * DAY
        ProcessUtilityBilling(T)
        assert_eq(houseUtilityBills('vinewood1', 'AND bill_period = ?', { cycle(T) })[1].target_id, 'NEWA')
        assert_eq(#houseUtilityBills('grove7', 'AND bill_period = ?', { cycle(T) }), 0, 'billed a house nobody owns')
        assert_eq(utility('vinewood1').owner_id, 'NEWA')
        assert_eq(utility('grove7').owner_id, nil)
        own('grove7', 'OWNB')
    end)
    it('pfm-houses still starting: houses wait and are billed for the same cycle later', function()
        local T = T0 + 70 * DAY
        PFHouses.dbReady = false
        local res = ProcessUtilityBilling(T)
        assert_eq(res.houses, 'not_ready')
        assert_true(res.housesPending, 'not worth a retry')
        assert_eq(#houseUtilityBills('vinewood1', 'AND bill_period = ?', { cycle(T) }), 0)
        PFHouses.dbReady = true
        res = ProcessUtilityBilling(T + 300, { housesOnly = true, period = res.period })
        assert_eq(#houseUtilityBills('vinewood1', 'AND bill_period = ?', { cycle(T) }), 1)
        -- pfm-houses not running at all: skipped, nothing to retry
        states['pfm-houses'] = 'stopped'
        res = ProcessUtilityBilling(T + DAY)
        assert_eq(res.houses, 'no_housing')
        assert_false(res.housesPending)
    end)
    it('old house bills stored without a payer are closed by migration 3', function()
        MySQL.query.await("SET SESSION sql_mode = ''")
        MySQL.insert.await("INSERT INTO pf_gov_bills (bill_type, target_type, target_id, amount, issued_by) VALUES ('utility', 'property', 'vinewood1', 225, 'system')")
        local junk = MySQL.single.await("SELECT id, target_type, status FROM pf_gov_bills WHERE target_type = '' ORDER BY id DESC LIMIT 1")
        assert_true(junk ~= nil, 'the lenient database kept the bill with an empty type')
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 3")
        GovSchema.__reset()
        assert_true(GovSchema.Ensure())
        assert_eq(bill(junk.id).status, 'waived')
    end)
end)

describe('the Fines app', function()
    it("lists the citizens' house bills, so staff can see and waive property tax", function()
        local P = Mock.newPlayer(CLERK, 'GOV1')
        P.PlayerData.job = { name = 'government', grade = { level = 1 }, onduty = true }
        local res = PropertyTax.Run(T0 + 14 * DAY)
        assert_eq(res.billed, 2)
        local tax = MySQL.single.await("SELECT * FROM pf_gov_bills WHERE bill_ref = 'house:vinewood1' AND bill_period = ?", { res.period })
        newBill('FINE1', 75, T0 + 30 * DAY)
        local function find(list, id) for _, b in ipairs(list) do if b.id == tonumber(id) then return b end end end
        local all = GovApps.Fines.recent(CLERK, {})
        assert_true(all.ok)
        local row = find(all.bills, tax.id)
        assert_true(row ~= nil, 'property tax not listed')
        assert_eq(row.kind, 'Property tax')
        assert_eq(row.targetType, 'citizen')
        local houses = GovApps.Fines.recent(CLERK, { filter = 'houses' })
        assert_true(find(houses.bills, tax.id) ~= nil)
        local utilityRow
        for _, b in ipairs(houses.bills) do if b.kind == 'House utilities' then utilityRow = b end end
        assert_true(utilityRow ~= nil, 'house utility bills not listed')
        for _, b in ipairs(houses.bills) do assert_true(b.type ~= 'fine', 'a fine under houses') end
        local fines = GovApps.Fines.recent(CLERK, { filter = 'fines' })
        assert_eq(find(fines.bills, tax.id), nil)
        assert_true(all.canWaive)
        assert_true(GovApps.Fines.waive(CLERK, { billId = tax.id, reason = 'Assessment error' }).ok)
        assert_eq(bill(tax.id).status, 'waived')
        assert_eq(GovApps.Fines.recent(CLERK, { filter = 'nonsense' }).filter, 'all')
    end)
end)
