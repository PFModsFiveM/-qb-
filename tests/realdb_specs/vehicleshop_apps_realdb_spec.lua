-- pfm-vehicleshop Car Dealer apps on the real database and the real ledger: a dealer sale accepted
-- by the buyer charges once, pays the dealership and the commission exactly once, takes one car from
-- the real stock table and records the sale once; finance instalments and pay-offs are charged once
-- per payment (a retry of the same payment after a crash does not charge again, a payment that
-- failed for lack of money does not block a later one); stock orders are paid by the dealership.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
QBCoreMock.Commands.Add = function() end
QBCoreMock.Functions.GetIdentifier = function(src) return 'license:' .. tostring(src) end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
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
assert(PFLedger.EnsureSociety('cardealer', 'job'), 'dealership account')
Mock.exportsByResource['pf-devices'] = { RegisterApp = function() return true end, RegisterAppHandlers = function() return true end, Push = function() return true end, PushToJob = function() return 0 end }

QBCoreMock.Shared.Vehicles = {
    cognoscenti = { name = 'Cognoscenti', brand = 'Enus', price = 100000, shop = 'luxury', category = 'sedans' },
}
function CreateVehicleServerSetter() return 501 end
function SetVehicleNumberPlateText() end

local function loadShop()
    function GetCurrentResourceName() return 'pfm-vehicleshop' end
    Config = nil
    load_resource('pfm-banking/payouts.lua')
    load_resource('pfm-vehicleshop/config.lua')
    load_resource('pfm-vehicleshop/server.lua')
    load_resource('pfm-vehicleshop/server_apps.lua')
    PFShop.Start()
end
loadShop()
assert(PFShop.dbReady, 'pfm-vehicleshop migrations')

local BUYER, DEALER = 1, 2
local LUX = Config.Shops.luxury.Location
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function society() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'cardealer'")) or 0 end
local function completed(pattern) return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { pattern })) or 0 end
local function stockOf() return tonumber(MySQL.scalar.await("SELECT stock FROM pfm_vehicleshop_stock WHERE shop = 'luxury' AND model = 'cognoscenti'")) end
local runNo = 0

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    runNo = runNo + 1
    local buyer = Mock.newPlayer(BUYER, 'VBUY' .. runNo)
    buyer.PlayerData.money = { cash = 0, bank = 500000 }
    buyer.PlayerData.license = 'license:1'
    local dealer = Mock.newPlayer(DEALER, 'VDEAL')
    dealer.PlayerData.money = { cash = 0, bank = 0 }
    dealer.PlayerData.license = 'license:2'
    dealer.PlayerData.job = { name = 'cardealer', onduty = true, grade = { level = 3 } }
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src Mock.coords[src] = vector3(LUX.x, LUX.y, LUX.z) end
end

describe('a dealer sale from the app', function()
    it('charges the buyer once and pays the dealership and the commission once', function()
        local before, stockBefore = society(), PFShop.StockOf('luxury', 'cognoscenti')
        local offer = PFShop.StaffOffer(DEALER, { model = 'cognoscenti', target = BUYER })
        assert_true(offer.ok, tostring(offer.error))
        assert_eq(bank(BUYER), 500000)
        local res = PFShop.AppAnswer(BUYER, { id = offer.offer.id, accept = true })
        assert_true(res.ok, tostring(res.error))
        assert_eq(PFShop.AppAnswer(BUYER, { id = offer.offer.id, accept = true }).error, 'not_found')
        assert_eq(bank(BUYER), 400000)
        assert_eq(society() - before, 100000)
        assert_eq(bank(DEALER), 100000 * Config.Commission)
        assert_eq(completed('pfm-vehicleshop:dealer:' .. offer.offer.id .. ':charge%'), 1)
        assert_eq(completed('pfm-vehicleshop:dealer:' .. offer.offer.id .. ':dealership'), 1)
        assert_eq(completed('pfm-vehicleshop:dealer:' .. offer.offer.id .. ':commission'), 1)
        assert_eq(stockOf(), stockBefore - 1)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pfm_vehicleshop_sales WHERE plate = ?', { res.plate })), 1)
        assert_eq(MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', { res.plate }), 'VBUY' .. runNo)
        local init = PFShop.StaffInit(DEALER)
        assert_true(init.stats.count >= 1)
        assert_true(#init.sales >= 1)
    end)
    it('an empty stock stops the sale; an order paid by the dealership refills it', function()
        MySQL.update.await("UPDATE pfm_vehicleshop_stock SET stock = 0 WHERE shop = 'luxury' AND model = 'cognoscenti'")
        assert_eq(PFShop.StaffOffer(DEALER, { model = 'cognoscenti', target = BUYER }).error, 'out_of_stock')
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 500000 WHERE account_name = 'cardealer'")
        local order = PFShop.OrderStock(DEALER, { shop = 'luxury', model = 'cognoscenti', qty = 2 })
        assert_true(order.ok, tostring(order.error))
        assert_eq(order.cost, 140000)
        assert_eq(society(), 360000)
        assert_eq(stockOf(), 2)
        assert_true(PFShop.StaffOffer(DEALER, { model = 'cognoscenti', target = BUYER }).ok)
    end)
end)

describe('finance payments from the app', function()
    local function financed(plate, cid)
        MySQL.insert.await([[INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime)
            VALUES ('l', ?, 'cognoscenti', '1', '{}', ?, 'pillboxgarage', 1, 9000, 1000, 9, 600)]], { cid, plate })
    end
    local function car(plate) return MySQL.single.await('SELECT balance, paymentamount, paymentsleft FROM player_vehicles WHERE plate = ?', { plate }) end

    it('an instalment is charged once and the balance follows; the rest is paid off once', function()
        local plate = 'FINR' .. runNo
        financed(plate, 'VBUY' .. runNo)
        assert_true(PFShop.AppPay(BUYER, { plate = plate }).ok)
        assert_eq(tonumber(car(plate).balance), 8000)
        assert_eq(tonumber(car(plate).paymentsleft), 8)
        assert_eq(bank(BUYER), 499000)
        assert_true(PFShop.AppPayOff(BUYER, { plate = plate }).ok)
        assert_eq(tonumber(car(plate).balance), 0)
        assert_eq(bank(BUYER), 491000)
        assert_eq(PFShop.AppPayOff(BUYER, { plate = plate }).error, 'alreadypaid')
        assert_eq(completed('pfm-vehicleshop:finance:VBUY' .. runNo .. ':' .. plate .. ':%'), 1)
        assert_eq(completed('pfm-vehicleshop:payoff:VBUY' .. runNo .. ':' .. plate .. ':%'), 1)
    end)
    it('the same payment retried after a crash does not charge again', function()
        local plate = 'FINC' .. runNo
        financed(plate, 'VBUY' .. runNo)
        assert_true(PFShop.AppPay(BUYER, { plate = plate }).ok)
        MySQL.update.await('UPDATE player_vehicles SET balance = 9000, paymentsleft = 9, paymentamount = 1000 WHERE plate = ?', { plate })
        loadShop()                                                        -- a restart: nothing in memory
        assert_true(PFShop.AppPay(BUYER, { plate = plate }).ok)
        assert_eq(bank(BUYER), 499000)
        assert_eq(tonumber(car(plate).balance), 8000)
        assert_eq(completed('pfm-vehicleshop:finance:VBUY' .. runNo .. ':' .. plate .. ':%'), 1)
    end)
    it('a payment without the money fails; with money later it goes through once, also after a restart', function()
        local plate = 'FINP' .. runNo
        financed(plate, 'VBUY' .. runNo)
        Mock.players[BUYER].PlayerData.money.bank = 100
        assert_eq(PFShop.AppPay(BUYER, { plate = plate }).error, 'notenoughmoney')
        loadShop()
        assert_eq(PFShop.AppPay(BUYER, { plate = plate }).error, 'notenoughmoney')
        Mock.players[BUYER].PlayerData.money.bank = 3000
        loadShop()
        assert_true(PFShop.AppPay(BUYER, { plate = plate }).ok)
        assert_eq(bank(BUYER), 2000)
        assert_eq(tonumber(car(plate).balance), 8000)
        assert_eq(PFShop.AppPay(DEALER, { plate = plate }).error, 'not_owned')
    end)
end)
