-- pf-government weekly property tax on a real database, with the real pfm-houses export
-- (GetOwnedHouses), the real bills and tax schedule, the real ledger and the real pf-citizen Bills
-- app: one 'tax' bill per house per week (the unique key, even when the job runs twice, after a
-- restart or racing another run), 0.5% of the price paid (the listing price when unknown) with a
-- $50 minimum, the mayor's rate, unpaid bills going delinquent like other bills with the house kept,
-- a house sold mid-week (the seller's bill stands, the buyer pays from the next week), and the bill
-- shown and paid in the owner's Bills app.
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
assert(PFLedger.EnsureSociety('realestate', 'job'), 'agency account')
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
    Push = function() return true end, PushToJob = function() return 0 end, PushToCitizen = function() return true end,
}

-- pfm-houses: listings and owners in its own tables, read only through its export
RealDB.exec('pfm-houses/qb-houses.sql')
MySQL.query.await('CREATE TABLE IF NOT EXISTS inventories (identifier VARCHAR(100) PRIMARY KEY, items LONGTEXT)')
local COORDS = '{"enter":{"x":100.0,"y":200.0,"z":30.0,"h":0.0},"cam":{"x":100.0,"y":200.0,"z":30.0,"h":0.0,"yaw":-10.0}}'
local function listing(name, label, price, owned)
    MySQL.insert.await("INSERT INTO houselocations (name, label, coords, owned, price, tier, garage) VALUES (?, ?, ?, ?, ?, 1, '{}')",
        { name, label, COORDS, owned and 1 or 0, price })
end
local function own(house, cid, paid)
    MySQL.insert.await('INSERT INTO player_houses (house, identifier, citizenid, keyholders) VALUES (?, ?, ?, ?)',
        { house, 'license:' .. cid, cid, json.encode({ cid }) })
    if paid then MySQL.update.await('UPDATE player_houses SET purchase_price = ? WHERE house = ? ORDER BY id DESC LIMIT 1', { paid, house }) end
end
listing('vinewood1', '1 Vinewood Hills', 300000, true)   -- bought for 250,000 before a reprice
listing('grove7', '7 Grove Street', 120000, true)        -- owned before prices were recorded
listing('shack', 'Sandy Shack', 6000, true)              -- cheap: the minimum applies
listing('forsale', 'For Sale Ave', 90000, false)         -- nobody owns it

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
threads[1]()                                    -- houselocations into Config.Houses
local housesConfig = Config
own('vinewood1', 'OWNA', 250000)
own('grove7', 'OWNB')                           -- no purchase_price: the listing price is the value
own('shack', 'OWNA', 6000)
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
    'server/licenses.lua', 'server/integrations.lua', 'server/staff.lua', 'server/callbacks.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
-- one Lua state holds both resources: pfm-houses reads its listings through the global Config
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
govX.PayBill = function(_, billId, amount, paidBy) return PayBill(billId, amount, paidBy) end

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
local W1 = 1793793600                 -- Wednesday 2026-11-04 12:00 UTC (week of 2026-11-02)
local W2, W3, W4, W5 = W1 + 7 * DAY, W1 + 14 * DAY, W1 + 21 * DAY, W1 + 28 * DAY

local function taxBills(where, params)
    return MySQL.query.await("SELECT * FROM pf_gov_bills WHERE bill_type = 'tax' AND " .. where .. ' ORDER BY id', params) or {}
end
local function houseBills(house) return taxBills('bill_ref = ?', { 'house:' .. house }) end
local function weekBills(period) return taxBills('bill_period = ?', { period }) end
local function count(where, params) return #taxBills(where, params) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    PFCitizen.__resetLimits()
    Mock.clock = W1
    states['pfm-houses'] = nil
end

describe('the schema and the housing export', function()
    it('adds the recurring columns and the unique key, safe to run again', function()
        assert_true(MigrationColumnExists('pf_gov_bills', 'bill_ref'))
        assert_true(MigrationColumnExists('pf_gov_bills', 'bill_period'))
        assert_true(MigrationIndexExists('pf_gov_bills', 'uq_bill_period_ref'))
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 2")
        GovSchema.__reset()
        assert_true(GovSchema.Ensure(), 'rerun')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 2")), 1)
    end)
    it('pfm-houses lists every owned house with its value: the price paid, else the listing price', function()
        local list = exports['pfm-houses']:GetOwnedHouses()
        local byHouse = {}
        for _, h in ipairs(list) do byHouse[h.house] = h end
        assert_eq(#list, 3)
        assert_eq(byHouse.vinewood1.citizenid, 'OWNA')
        assert_eq(byHouse.vinewood1.value, 250000, 'price paid, not the repriced listing')
        assert_eq(byHouse.vinewood1.label, '1 Vinewood Hills')
        assert_eq(byHouse.grove7.value, 120000, 'nothing recorded: the listing price')
        assert_eq(byHouse.shack.value, 6000)
        assert_eq(byHouse.forsale, nil, 'unowned houses are not listed')
    end)
    it('reads everything from the database: right before pfm-houses has loaded its listings', function()
        local loaded = Config.Houses
        Config.Houses = {}
        local list = exports['pfm-houses']:GetOwnedHouses()
        Config.Houses = loaded
        local byHouse = {}
        for _, h in ipairs(list) do byHouse[h.house] = h end
        assert_eq(byHouse.grove7.value, 120000)
        assert_eq(byHouse.grove7.label, '7 Grove Street')
    end)
    it('a house with two rows counts once, with its newest row', function()
        listing('dup', 'Dup Lane', 50000, true)
        own('dup', 'OLDD', 40000)
        own('dup', 'NEWD', 45000)
        local found = {}
        for _, h in ipairs(exports['pfm-houses']:GetOwnedHouses()) do if h.house == 'dup' then found[#found + 1] = h end end
        MySQL.query.await("DELETE FROM player_houses WHERE house = 'dup'")
        MySQL.query.await("DELETE FROM houselocations WHERE name = 'dup'")
        assert_eq(#found, 1)
        assert_eq(found[1].citizenid, 'NEWD')
        assert_eq(found[1].value, 45000)
    end)
end)

describe('one bill per house per week', function()
    it('bills each owned house to its owner: 0.5% of the value, at least $50', function()
        local res = PropertyTax.Run(W1)
        assert_eq(res.period, '2026-11-02')
        assert_eq(res.billed, 3)
        local v = houseBills('vinewood1')[1]
        assert_eq(v.target_type, 'citizen')
        assert_eq(v.target_id, 'OWNA')
        assert_eq(tonumber(v.amount), 1250)
        assert_eq(v.status, 'unpaid')
        assert_eq(v.bill_period, '2026-11-02')
        assert_eq(v.issued_by, 'system')
        assert_true(tostring(v.description):find('1 Vinewood Hills', 1, true) ~= nil, tostring(v.description))
        assert_near(v.due_date / 1000, W1 + 7 * DAY, 1, 'due in 7 days')
        assert_eq(tonumber(houseBills('grove7')[1].amount), 600, '0.5% of the listing price')
        assert_eq(houseBills('grove7')[1].target_id, 'OWNB')
        assert_eq(tonumber(houseBills('shack')[1].amount), 50, '0.5% of 6,000 is 30: the minimum')
        assert_eq(#houseBills('forsale'), 0)
    end)
    it('a second run in the same week bills nothing', function()
        Mock.clock = W1 + 2 * DAY
        local res = PropertyTax.Run(Mock.clock)
        assert_eq(res.billed, 0)
        assert_eq(res.existing, 3)
        assert_eq(#weekBills('2026-11-02'), 3)
    end)
    it('nor does the first run after a restart (fresh module state, the console command)', function()
        GovSchema.__reset()
        PropertyTax = nil
        load_resource('[pfscripts]/pf-government/server/property_tax.lua')
        assert_eq(PropertyTax.Run(W1 + 3 * DAY).billed, 0)
        Mock.clock = W1 + 4 * DAY
        Mock.rawCommands.govpropertytax(0)
        assert_eq(#weekBills('2026-11-02'), 3)
    end)
    it('a run racing another one: the database keeps one bill', function()
        -- another run bills grove7 for week 2 between this run's read and its insert
        local queryAwait = MySQL.query.await
        MySQL.query.await = function(q, p)
            local out = queryAwait(q, p)
            if q:find('bill_ref LIKE', 1, true) then
                MySQL.query.await = queryAwait
                assert_true(CreateBill('citizen', 'OWNB', 600, 'tax', nil, 'Property tax: 7 Grove Street', 'system', 'Tax Office',
                    { ref = 'house:grove7', period = '2026-11-09' }), 'the other run')
            end
            return out
        end
        local res = PropertyTax.Run(W2)
        MySQL.query.await = queryAwait
        assert_eq(res.billed, 2)
        assert_eq(res.existing, 1)
        assert_eq(count('bill_ref = ? AND bill_period = ?', { 'house:grove7', '2026-11-09' }), 1)
        assert_eq(#weekBills('2026-11-09'), 3)
    end)
    it('the unique key refuses a second bill for a house and week whatever inserts it', function()
        local ok, msg, existing = CreateBill('citizen', 'OWNA', 1250, 'tax', nil, 'again', 'system', 'Tax Office',
            { ref = 'house:vinewood1', period = '2026-11-02' })
        assert_false(ok)
        assert_eq(msg, 'duplicate')
        assert_eq(existing, tonumber(houseBills('vinewood1')[1].id))
        local raw = pcall(MySQL.insert.await, [[INSERT INTO pf_gov_bills (bill_type, target_type, target_id, amount, issued_by, bill_ref, bill_period)
            VALUES ('tax', 'citizen', 'OWNA', 1, 'x', 'house:vinewood1', '2026-11-02')]])
        assert_false(raw, 'a plain INSERT fails on the key')
        assert_eq(count('bill_ref = ? AND bill_period = ?', { 'house:vinewood1', '2026-11-02' }), 1)
        -- other bills have no period and are not limited
        assert_true(CreateBill('citizen', 'OWNA', 100, 'fine', nil, 'Speeding', 'GOV1', 'Officer'))
        assert_true(CreateBill('citizen', 'OWNA', 100, 'fine', nil, 'Speeding', 'GOV1', 'Officer'))
    end)
end)

describe('a house sold mid-week', function()
    it('keeps the seller\'s bill for the week; the buyer pays from the next week', function()
        -- week 3: billed to OWNB, then sold to BUYR on Thursday (as pfm-houses' sale does)
        assert_eq(PropertyTax.Run(W3).billed, 3)
        MySQL.update.await("UPDATE player_houses SET citizenid = 'BUYR', identifier = 'license:BUYR', keyholders = '[\"BUYR\"]' WHERE house = 'grove7'")
        assert_eq(PropertyTax.Run(W3 + DAY).billed, 0, 'no second bill this week')
        local w3 = taxBills('bill_ref = ? AND bill_period = ?', { 'house:grove7', '2026-11-16' })
        assert_eq(#w3, 1)
        assert_eq(w3[1].target_id, 'OWNB', 'the seller owned it when the week was billed')
        -- week 4: the buyer
        assert_eq(PropertyTax.Run(W4).billed, 3)
        local w4 = taxBills('bill_ref = ? AND bill_period = ?', { 'house:grove7', '2026-11-23' })
        assert_eq(w4[1].target_id, 'BUYR')
        assert_eq(count("target_id = 'OWNB' AND bill_period = '2026-11-23'", {}), 0)
    end)
    it('a house given back to the state is not billed from the next week', function()
        MySQL.query.await("DELETE FROM player_houses WHERE house = 'shack'")
        assert_eq(PropertyTax.Run(W5).billed, 2)
        assert_eq(count("bill_ref = 'house:shack' AND bill_period = '2026-11-30'", {}), 0)
        MySQL.insert.await("INSERT INTO player_houses (house, identifier, citizenid, keyholders, purchase_price) VALUES ('shack', 'license:OWNA', 'OWNA', '[\"OWNA\"]', 6000)")
        assert_eq(PropertyTax.Run(W5 + DAY).billed, 1, 'bought back the same week: billed for it once')
    end)
end)

describe('the rate', function()
    it('is the mayor\'s: a new rate applies from the next bills; a disabled tax bills nothing', function()
        local W6, W7 = W1 + 35 * DAY, W1 + 42 * DAY
        assert_true(SetTaxRate('property', 1.0, 'GOV1', 'Mayor'))
        assert_eq(PropertyTax.Run(W6).billed, 3)
        assert_eq(tonumber(taxBills("bill_ref = 'house:vinewood1' AND bill_period = '2026-12-07'", {})[1].amount), 2500)
        assert_eq(tonumber(taxBills("bill_ref = 'house:shack' AND bill_period = '2026-12-07'", {})[1].amount), 60, '1% of 6,000')
        assert_false(SetTaxRate('property', 6, 'GOV1', 'Mayor'), 'above the configured cap')
        assert_true(SetTaxEnabled('property', false, 'GOV1', 'Mayor'))
        assert_eq(PropertyTax.Run(W7).off, 'tax_off')
        assert_eq(#weekBills('2026-12-14'), 0)
        assert_true(SetTaxEnabled('property', true, 'GOV1', 'Mayor'))
        assert_true(SetTaxRate('property', 0.5, 'GOV1', 'Mayor'))
    end)
    it('no housing resource, no bills', function()
        states['pfm-houses'] = 'stopped'
        assert_eq(PropertyTax.Run(W1 + 49 * DAY).off, 'no_housing')
        assert_eq(#weekBills('2026-12-21'), 0)
    end)
end)

describe('the city hall business overview', function()
    it('counts unpaid business tax only, not the citizens\' property tax', function()
        assert_true(CreateBill('business', 'restaurant:bs', 300, 'tax', nil, 'Business tax for revenue period', 'system', 'Government'))
        local isGov = IsGovernmentEmployee
        IsGovernmentEmployee = function() return true end
        local out
        Government.NuiCallbacks['business:getStats']({ source = 1 }, function(res) out = res end)
        IsGovernmentEmployee = isGov
        assert_true(out and out.ok, 'stats')
        assert_true(count("target_type = 'citizen' AND status = 'unpaid'", {}) > 0, 'property tax bills are open')
        assert_eq(out.stats.alerts.unpaidTaxes, 1)
    end)
end)

describe('unpaid bills', function()
    it('go delinquent like other bills, and the house stays with its owner', function()
        local bill = taxBills("bill_ref = 'house:vinewood1' AND bill_period = '2026-11-02'", {})[1]
        Mock.clock = W1 + 10 * DAY
        ProcessBillEscalation()
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_gov_bills WHERE id = ?', { bill.id }), 'unpaid', '3 days overdue: not yet')
        Mock.clock = W1 + 15 * DAY   -- due + 7 escalation days have passed
        ProcessBillEscalation()
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_gov_bills WHERE id = ?', { bill.id }), 'delinquent')
        assert_eq(MySQL.scalar.await("SELECT citizenid FROM player_houses WHERE house = 'vinewood1'"), 'OWNA', 'no repossession')
        assert_eq(tonumber(MySQL.scalar.await("SELECT owned FROM houselocations WHERE name = 'vinewood1'")), 1)
    end)
    it('show in the owner\'s Bills app and are paid there once', function()
        local P = Mock.newPlayer(1, 'OWNA')
        P.PlayerData.money = { cash = 0, bank = 5000 }
        local bill = taxBills("bill_ref = 'house:vinewood1' AND bill_period = '2026-11-02'", {})[1]
        local list = Bills.List(1)
        assert_true(list.ok)
        local shown
        for _, b in ipairs(list.open) do if b.key == 'gov:' .. bill.id then shown = b end end
        assert_true(shown ~= nil, 'listed')
        assert_eq(shown.kind, 'Tax')
        assert_eq(shown.status, 'delinquent')
        assert_eq(shown.remaining, 1250)
        assert_true(shown.canPay)
        assert_true(tostring(shown.title):find('Property tax', 1, true) ~= nil, tostring(shown.title))
        local treasury = GetTreasuryBalance()
        local paid = Bills.Pay(1, { key = 'gov:' .. bill.id })
        assert_true(paid.ok, tostring(paid.error))
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_gov_bills WHERE id = ?', { bill.id }), 'paid')
        assert_eq(P.PlayerData.money.bank, 3750)
        assert_near(GetTreasuryBalance() - treasury, 1250, 0.001, 'into the city treasury')
        assert_false((Bills.Pay(1, { key = 'gov:' .. bill.id })).ok, 'not twice')
        assert_eq(P.PlayerData.money.bank, 3750)
        -- the other owner does not see it
        Mock.newPlayer(2, 'OWNB')
        for _, b in ipairs(Bills.List(2).open) do assert_true(b.key ~= 'gov:' .. bill.id, 'not listed for another citizen') end
    end)
end)

describe('pfm-houses still starting', function()
    it('reports no houses until it can read the prices paid; the run waits and then bills the price paid', function()
        local W9 = W1 + 56 * DAY                       -- week of 2026-12-28
        PFHouses.dbReady = false
        local list, why = exports['pfm-houses']:GetOwnedHouses()
        -- false rather than nil: a nil first value could lose the reason across the export boundary
        assert_eq(list, false, 'listing prices handed out as values')
        assert_eq(why, 'not_ready')
        local res = PropertyTax.Run(W9)
        assert_eq(res.off, 'not_ready')
        assert_true(res.retry, 'the scheduled task would wait a whole interval')
        assert_eq(#weekBills('2026-12-28'), 0, 'billed on listing prices')
        PFHouses.dbReady = true
        res = PropertyTax.Run(W9 + 120)
        assert_eq(res.billed, 3)
        assert_eq(tonumber(taxBills("bill_ref = 'house:vinewood1' AND bill_period = '2026-12-28'", {})[1].amount), 1250, '0.5% of the 250,000 paid, not of the 300,000 listing')
    end)
end)
