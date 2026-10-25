-- pf-government business premises on a real database: officials approve typed slots where they stand,
-- the owner buys matching equipment once from the business account, a persistent fixture stands at the
-- slot (pfm-worldobjects) and comes back after a restart, and business resources are told.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
GetInvokingResource = GetInvokingResource or function() return nil end
local states = { ['pfm-cityhall'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

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
assert(PFLedger.Start(), 'ledger start')

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/treasury.lua', 'server/taxes.lua', 'server/utilities.lua',
    'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua', 'server/integrations.lua',
    'server/staff.lua', 'server/callbacks.lua', 'server/premises.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
-- from pf-government server/main.lua (not loaded here: it starts the background tasks)
function IsGovernmentEmployee(src) local P = QBCoreMock.Functions.GetPlayer(src) return P ~= nil and P.PlayerData.job.name == Config.GovernmentJob end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()

-- pfm-worldobjects for the fixtures
local govConfig = Config
Config = nil
load_resource('pfm-worldobjects/config.lua')
govConfig.WorldObjects = Config.WorldObjects
Config = govConfig
local spawned = {}
function CreateObjectNoOffset(model, x, y, z) Mock.nextNetId = Mock.nextNetId + 1 spawned[Mock.nextNetId] = { x = x, y = y, z = z } return Mock.nextNetId end
function SetEntityRotation(e, rx, ry, rz) if spawned[e] then spawned[e].rz = rz end end
function FreezeEntityPosition() end
function GetEntityHeading() return 90.0 end
load_resource('pfm-worldobjects/server.lua')
Mock.exportsByResource['pfm-worldobjects'] = Mock.exportsByResource['__self']
assert(PFWorldObjects.Start())

-- pf-restaurants stand-in: its owner role answers premises.buy
local restaurantOwners = {}
Mock.exportsByResource['pf-restaurants'] = {
    HasPermission = function(_, src, id, perm) return restaurantOwners[src] == id and perm == 'premises.buy' end,
}
local changed = {}
AddEventHandler('pf-government:server:equipmentChanged', function(id) changed[#changed + 1] = id end)

local OFFICIAL, OWNER, MANAGER, MECHBOSS = 1, 2, 3, 4
local BIZ = 'restaurant:bs'
local SPOT = vector3(-1201.0, -897.8, 13.98)
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function fund(name, amount)
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, ?, 'business', '[]') ON DUPLICATE KEY UPDATE account_balance = VALUES(account_balance)", { name, amount })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', { 'society:' .. name, amount })
end
local function slots() return MySQL.query.await('SELECT * FROM pf_gov_premises_slots WHERE business_id = ? AND active = 1 ORDER BY id', { BIZ }) end

RegisterBusiness(BIZ, 'Burger Shot', 'restaurant', 'unowned', nil, 'society:restaurant_bs')
RegisterBusiness('mechanic:bennys', 'Bennys', 'mechanic', 'job:bennys', nil, 'society:bennys')

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(OFFICIAL, 'GOV1').PlayerData.job = { name = 'government', grade = { level = 3 }, onduty = true }
    Mock.newPlayer(OWNER, 'OWN1')
    Mock.newPlayer(MANAGER, 'MGR1')
    Mock.newPlayer(MECHBOSS, 'MEC1').PlayerData.job = { name = 'bennys', isboss = true, grade = { level = 4 } }
    restaurantOwners = { [OWNER] = 'bs' }
    Mock.coords = { [OFFICIAL] = SPOT, [OWNER] = SPOT, [MANAGER] = SPOT, [MECHBOSS] = SPOT }
    changed = {}
end

describe('approved slots', function()
    it('an official approves a slot where they stand; others cannot', function()
        assert_false(Premises.ApproveSlot(OWNER, BIZ, 'fridge'), 'not an official')
        local ok, id = Premises.ApproveSlot(OFFICIAL, BIZ, 'fridge', 'Back fridge')
        assert_true(ok, tostring(id))
        local s = slots()[1]
        assert_eq(s.slot_type, 'fridge')
        assert_true(math.abs(s.x - SPOT.x) < 0.01 and math.abs(s.y - SPOT.y) < 0.01, 'at the official')
        assert_eq(s.heading, 90.0)
        assert_eq(s.approved_by, 'GOV1')
    end)
    it('unknown slot types, unknown businesses and overlapping slots are refused', function()
        assert_false(Premises.ApproveSlot(OFFICIAL, BIZ, 'helipad'))
        assert_false(Premises.ApproveSlot(OFFICIAL, 'restaurant:nowhere', 'fridge'))
        local ok, err = Premises.ApproveSlot(OFFICIAL, BIZ, 'shelf')
        assert_false(ok)
        assert_eq(err, 'too_close')
        Mock.coords[OFFICIAL] = SPOT + vector3(3.0, 0.0, 0.0)
        assert_true(Premises.ApproveSlot(OFFICIAL, BIZ, 'shelf'))
    end)
end)

describe('buying equipment', function()
    it('only the owner, at the slot, with the matching type, paid once from the business account', function()
        fund('restaurant_bs', 10000)
        local fridgeSlot = slots()[1].id
        local price = Config.Premises.Equipment.fridge_commercial.price
        local ok, err = Premises.BuyEquipment(MANAGER, fridgeSlot, 'fridge_commercial')
        assert_false(ok) assert_eq(err, 'not_owner')
        ok, err = Premises.BuyEquipment(OWNER, fridgeSlot, 'shelf_dry')
        assert_false(ok) assert_eq(err, 'wrong_slot_type')
        Mock.coords[OWNER] = SPOT + vector3(40.0, 0.0, 0.0)
        ok, err = Premises.BuyEquipment(OWNER, fridgeSlot, 'fridge_commercial')
        assert_false(ok) assert_eq(err, 'too_far')
        Mock.coords[OWNER] = SPOT
        assert_eq(society('restaurant_bs'), 10000, 'nothing charged for refused requests')
        ok, err = Premises.BuyEquipment(OWNER, fridgeSlot, 'fridge_commercial')
        assert_true(ok, tostring(err))
        assert_eq(society('restaurant_bs'), 10000 - price)
        ok, err = Premises.BuyEquipment(OWNER, fridgeSlot, 'fridge_commercial')
        assert_false(ok) assert_eq(err, 'slot_in_use')
        assert_eq(society('restaurant_bs'), 10000 - price, 'paid once')
        assert_eq(changed[1], BIZ, 'business resources told')
        local installed = exports['pf-government']:GetInstalledEquipment(BIZ)
        assert_eq(#installed, 1)
        assert_eq(installed[1].storage.area, 'fridge')
    end)
    it('the equipment stands at the approved slot and comes back after a restart', function()
        local eq = MySQL.single.await('SELECT * FROM pf_gov_premises_equipment WHERE business_id = ?', { BIZ })
        local fixture = MySQL.single.await('SELECT * FROM pf_world_objects WHERE id = ?', { eq.fixture_id })
        assert_eq(fixture.kind, 'fixture')
        assert_eq(fixture.state, 'installed')
        local s = slots()[1]
        assert_true(math.abs(fixture.x - s.x) < 0.01 and math.abs(fixture.y - s.y) < 0.01)
        assert_eq(tonumber(fixture.rz), 90.0)
        spawned = {}
        load_resource('pfm-worldobjects/server.lua')
        assert_true(PFWorldObjects.Start())
        local entity = PFWorldObjects.entities[fixture.id]
        assert_true(entity ~= nil, 'respawned')
        assert_eq(spawned[entity].rz, 90.0)
        assert_false(PFWorldObjects.Unpack(OWNER, fixture.id).ok, 'a fixture is not a delivery')
        assert_false(PFWorldObjects.Move(OWNER, fixture.id).ok)
    end)
    it('an underfunded business is refused and nothing is installed', function()
        fund('restaurant_bs', 10)
        local shelf = slots()[2].id
        local ok, err = Premises.BuyEquipment(OWNER, shelf, 'shelf_dry')
        assert_false(ok) assert_eq(err, 'insufficient_funds')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_gov_premises_equipment WHERE slot_id = ?', { shelf })), 0)
    end)
    it('a closed business cannot buy; a slot in use cannot be withdrawn', function()
        fund('restaurant_bs', 10000)
        MySQL.update.await("UPDATE pf_gov_businesses SET business_status = 'closed' WHERE business_id = ?", { BIZ })
        local ok, err = Premises.BuyEquipment(OWNER, slots()[2].id, 'shelf_dry')
        assert_false(ok) assert_eq(err, 'business_closed')
        MySQL.update.await("UPDATE pf_gov_businesses SET business_status = 'active' WHERE business_id = ?", { BIZ })
        ok, err = Premises.RemoveSlot(OFFICIAL, slots()[1].id)
        assert_false(ok) assert_eq(err, 'slot_in_use')
        assert_true(Premises.RemoveSlot(OFFICIAL, slots()[2].id), 'an empty slot can be withdrawn')
    end)
    it('a job-owned business is managed by a boss of that job', function()
        fund('bennys', 5000)
        local there = SPOT + vector3(10.0, 0.0, 0.0)
        Mock.coords[OFFICIAL] = there
        local ok, slotId = Premises.ApproveSlot(OFFICIAL, 'mechanic:bennys', 'register')
        assert_true(ok, tostring(slotId))
        Mock.coords[MECHBOSS] = there
        Mock.coords[OWNER] = there
        assert_false(Premises.BuyEquipment(OWNER, slotId, 'register_pos'), 'not their business')
        assert_true(Premises.BuyEquipment(MECHBOSS, slotId, 'register_pos'))
        assert_eq(society('bennys'), 5000 - Config.Premises.Equipment.register_pos.price)
    end)
    it('the government app lists premises for staff and the owner only', function()
        local function nui(src, action, data)
            local got
            data = data or {}
            data.source = src
            Government.NuiCallbacks[action](data, function(r) got = r end)
            return got
        end
        assert_true(nui(OFFICIAL, 'premises:list', { businessId = BIZ }).ok)
        assert_true(nui(OWNER, 'premises:list', { businessId = BIZ }).ok)
        assert_false(nui(MANAGER, 'premises:list', { businessId = BIZ }).ok)
    end)
end)
