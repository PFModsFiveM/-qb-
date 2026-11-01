-- pfm-vehicleshop settlements on the real database and the real ledger: the migration creates the
-- owed-payment and held-sale tables (rerun-safe); an owed payment survives in its table and the
-- sweep pays it, moving past a dead key to the next numbered key, once; a purchase whose charge the
-- bank could not confirm is held in its table and, once the ledger's recovery completes the charge,
-- the car is written parked in the delivery garage (once); a finance payment held the same way is
-- applied once; repossession deletes only an overdue car of its owner and closes its fleet entry when
-- pf-jobgarages is not running.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing', ['pf-devices'] = 'missing', ['pf-citizen'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.GetIdentifier = function(src) return 'license:' .. tostring(src) end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('[pfscripts]/pf-jobgarages/sql/pf_jobgarages.sql')
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

QBCoreMock.Shared.Vehicles = { blista = { name = 'Blista', price = 10000, shop = 'pdm', category = 'compacts' } }

function GetCurrentResourceName() return 'pfm-vehicleshop' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-vehicleshop/config.lua')
load_resource('pfm-vehicleshop/settlements.lua')
load_resource('pfm-vehicleshop/server.lua')
load_resource('pfm-vehicleshop/server_apps.lua')
PFShop.Start()
assert(PFShop.dbReady, 'pfm-vehicleshop migrations')

-- the write that completes a charge fails once (the money left the buyer; recovery completes it)
local failCredit = false
local realUpdate = MySQL.update
MySQL.update = setmetatable({ await = function(q, p)
    if failCredit and q == PFLedger.SQL.setState and p[1] == 'completed' and p[4] == 'debited' then
        failCredit = false
        error('injected: the credit write failed')
    end
    return realUpdate.await(q, p)
end }, { __call = function(_, ...) return realUpdate(...) end })

local BUYER = 1
local PDM = Config.Shops.pdm.Location
local runNo, cid = 0, nil
local function money(src) return Mock.players[src].PlayerData.money end
local function completed(pattern) return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { pattern })) or 0 end
-- the ledger's recovery only touches transfers older than its stale window
local function ageLedger() MySQL.update.await("UPDATE pf_transactions SET updated_at = NOW() - INTERVAL 10 MINUTE WHERE state IN ('pending', 'debited')") end
local function settle() ageLedger() PFLedger.Recover() PFSettle.Sweep() end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    runNo = runNo + 1
    cid = 'VSET' .. runNo
    local p = Mock.newPlayer(BUYER, cid)
    p.PlayerData.money = { cash = 20000, bank = 200000 }
    p.PlayerData.license = 'license:1'
    p.PlayerData.source = BUYER
    Mock.coords[BUYER] = vector3(PDM.x, PDM.y, PDM.z)
    failCredit = false
    states['pfm-banking'] = nil
    states['pf-jobgarages'] = nil
end

describe('the settlement tables', function()
    it('the migration creates both tables, and every step can run again', function()
        for _, t in ipairs({ 'pfm_vehicleshop_owed', 'pfm_vehicleshop_held' }) do
            local n = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }))
            assert_eq(n, 1, t)
        end
        for _, step in ipairs(PFShop.Migrations[2].up) do MySQL.query.await(step) end
        assert_true(RunMigrations('pfm-vehicleshop', PFShop.Migrations))
    end)
end)

describe('owed payments on the database', function()
    it('a payment the bank cannot take now is stored, survives, and is paid by the sweep once', function()
        local key = 'pfm-vehicleshop:test:' .. runNo .. ':seller'
        states['pfm-banking'] = 'missing'
        assert_false(PFSettle.Owe({ key = key, to = cid, account = 'bank', amount = 2500, kind = 'sale', reason = 'test' }))
        states['pfm-banking'] = nil
        local row = MySQL.single.await('SELECT * FROM pfm_vehicleshop_owed WHERE ledger_key = ?', { key })
        assert_true(row ~= nil, 'stored')
        assert_eq(row.state, 'open')
        assert_eq(row.to_id, cid)
        assert_eq(tonumber(row.amount), 2500)
        -- the same payment owed again (a re-run) is not a second row
        states['pfm-banking'] = 'missing'
        PFSettle.Owe({ key = key, to = cid, account = 'bank', amount = 2500, kind = 'sale', reason = 'test' })
        states['pfm-banking'] = nil
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pfm_vehicleshop_owed WHERE ledger_key = ?', { key })), 1)
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 202500)
        assert_eq(MySQL.scalar.await('SELECT state FROM pfm_vehicleshop_owed WHERE ledger_key = ?', { key }), 'paid')
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 202500, 'once')
        assert_eq(completed(key .. '%'), 1)
    end)

    it('a key the ledger closed without paying moves to the next numbered key', function()
        local key = 'pfm-vehicleshop:test:' .. runNo .. ':refund'
        states['pfm-banking'] = 'missing'
        PFSettle.Owe({ key = key, to = cid, account = 'bank', amount = 700, kind = 'refund', reason = 'test' })
        states['pfm-banking'] = nil
        -- the first key was used and failed (a transfer recovery closed)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, error)
            VALUES (?, ?, 'refund', 'system:pfm-vehicleshop', ?, 700, 'failed', 'interrupted')]], { 'TXDEAD' .. runNo, key, 'player:' .. cid .. ':bank' })
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 200700)
        local row = MySQL.single.await('SELECT attempt, state FROM pfm_vehicleshop_owed WHERE ledger_key = ?', { key })
        assert_eq(tonumber(row.attempt), 2)
        assert_eq(row.state, 'paid')
        assert_eq(completed(key .. ':r2'), 1)
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 200700)
    end)
end)

describe('held sales on the database', function()
    it('a purchase whose charge completes later gives one car, parked in the delivery garage', function()
        failCredit = true
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        assert_eq(money(BUYER).cash, 10000)
        assert_eq(money(BUYER).bank, 200000)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_vehicles WHERE citizenid = ?', { cid })), 0)
        local hold = MySQL.single.await('SELECT * FROM pfm_vehicleshop_held WHERE citizenid = ?', { cid })
        assert_true(hold ~= nil)
        assert_eq(hold.state, 'waiting')
        assert_eq(hold.flow, 'showroom')
        assert_eq(json.decode(hold.data).model, 'blista')
        PFSettle.Sweep()
        assert_eq(MySQL.scalar.await('SELECT state FROM pfm_vehicleshop_held WHERE id = ?', { hold.id }), 'waiting', 'not settled yet')
        settle()
        local car = MySQL.single.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { cid })
        assert_true(car ~= nil, 'the car is written')
        assert_eq(car.vehicle, 'blista')
        assert_eq(tonumber(car.state), 1)
        assert_eq(car.garage, Config.DeliveryGarage)
        local after = MySQL.single.await('SELECT state, outcome FROM pfm_vehicleshop_held WHERE id = ?', { hold.id })
        assert_eq(after.state, 'done')
        assert_eq(after.outcome, 'charged:cash')
        settle()
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_vehicles WHERE citizenid = ?', { cid })), 1, 'one car')
        assert_eq(money(BUYER).cash, 10000)
        assert_eq(money(BUYER).bank, 200000)
    end)

    it('a charge key held again reuses its row (a retried payment)', function()
        local h1 = PFSettle.Hold({ flow = 'payment', key = 'pfm-vehicleshop:test:held:' .. runNo, accounts = { 'cash', 'bank' }, citizenid = cid, amount = 5, data = { a = 1 } })
        MySQL.update.await("UPDATE pfm_vehicleshop_held SET state = 'done', outcome = 'none' WHERE id = ?", { h1.id })
        local h2 = PFSettle.Hold({ flow = 'payment', key = 'pfm-vehicleshop:test:held:' .. runNo, accounts = { 'cash', 'bank' }, citizenid = cid, amount = 5, data = { a = 2 } })
        assert_eq(h2.id, h1.id)
        local row = MySQL.single.await('SELECT state, outcome, data FROM pfm_vehicleshop_held WHERE id = ?', { h1.id })
        assert_eq(row.state, 'waiting')
        assert_eq(row.outcome, nil)
        assert_eq(json.decode(row.data).a, 2)
        MySQL.update.await("UPDATE pfm_vehicleshop_held SET state = 'done' WHERE id = ?", { h1.id })
    end)

    it('a finance payment whose charge completes later is applied to the loan once', function()
        local plate = 'VSF' .. runNo
        MySQL.insert.await([[INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime)
            VALUES ('license:1', ?, 'blista', '1', '{}', ?, 'pillboxgarage', 1, 8000, 1000, 8, 100)]], { cid, plate })
        failCredit = true
        local res = PFShop.FinancePayment(BUYER, plate, 1000)
        assert_eq(res.error, 'payment_held')
        assert_eq(money(BUYER).bank, 200000, 'nothing from the bank on top')
        assert_eq(tonumber(MySQL.scalar.await('SELECT balance FROM player_vehicles WHERE plate = ?', { plate })), 8000)
        settle()
        local row = MySQL.single.await('SELECT balance, paymentsleft, paymentamount FROM player_vehicles WHERE plate = ?', { plate })
        assert_eq(tonumber(row.balance), 7000)
        assert_eq(tonumber(row.paymentsleft), 7)
        settle()
        assert_eq(tonumber(MySQL.scalar.await('SELECT balance FROM player_vehicles WHERE plate = ?', { plate })), 7000, 'once')
        assert_eq(money(BUYER).cash, 19000)
    end)
end)

describe('repossession on the database', function()
    it('only an overdue car of its owner; its fleet entry is closed when pf-jobgarages is not running', function()
        local plate, other = 'VSR' .. runNo, 'VSQ' .. runNo
        MySQL.insert.await([[INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime)
            VALUES ('license:1', ?, 'blista', '1', '{}', ?, 'pillboxgarage', 1, 5000, 1000, 5, 0), ('license:1', ?, 'blista', '1', '{}', ?, 'pillboxgarage', 1, 5000, 1000, 5, 90)]],
            { cid, plate, cid, other })
        MySQL.insert.await("INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, assignment_type) VALUES ('mechanic_main', ?, 'blista', 'x', 0, 1, 'none')", { plate })
        states['pf-jobgarages'] = 'missing'
        assert_false(PFShop.Repossess('SOMEONE', plate), 'not the owner')
        assert_false(PFShop.Repossess(cid, other), 'not overdue')
        assert_true(PFShop.Repossess(cid, plate))
        assert_eq(MySQL.scalar.await('SELECT id FROM player_vehicles WHERE plate = ?', { plate }), nil)
        assert_true(MySQL.scalar.await('SELECT id FROM player_vehicles WHERE plate = ?', { other }) ~= nil)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM job_garage_vehicles WHERE plate = ? AND active = 1', { plate })), 0)
    end)
end)
