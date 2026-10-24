-- pfm-vehicleshop on the ledger: pay before the car, server-checked shops and finance terms, and
-- dealer sales / paid transfers only after the customer accepts.
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.GetIdentifier = function(src) return 'license:' .. tostring(src) end
QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = {
    blista = { name = 'Blista', price = 10000, shop = 'pdm', category = 'compacts' },
    cognoscenti = { name = 'Cognoscenti', price = 100000, shop = 'luxury', category = 'sedans' },
}

local vehicles = {}   -- player_vehicles: [plate] = row
FakeDB.extraPatterns = {
    { 'SELECT plate FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and p[1] or nil end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], balance = p[9], paymentamount = p[10], paymentsleft = p[11], financetime = p[12] }
        return 1
    end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state)', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], balance = 0 }
        return 1
    end },
    { 'SELECT balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[5]]
        if v and v.citizenid == p[6] then v.balance, v.paymentamount, v.paymentsleft, v.financetime = p[1], p[2], p[3], p[4] end
        return 1
    end },
    { 'SELECT * FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and { vehicles[p[1]] } or {} end },
    { 'SELECT citizenid, balance FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and { vehicles[p[1]] } or {} end },
    { 'UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', function(p) vehicles[p[3]].citizenid = p[1]; return 1 end },
}

LedgerEnv.load('pfm-vehicleshop', { 'pfm-vehicleshop/config.lua', 'pfm-vehicleshop/server.lua' })

local BUYER, DEALER, STRANGER = 1, 2, 3
local PDM = Config.Shops.pdm.Location
local LUX = Config.Shops.luxury.Location
local function money(src) return Mock.players[src].PlayerData.money end
local function count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end
local function first() for _, v in pairs(vehicles) do return v end end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.vehicleOf, Mock.plates = {}, {}
    vehicles = {}
    FakeDB.society('cardealer', 0)
    for src, cash in pairs({ [BUYER] = 0, [DEALER] = 0, [STRANGER] = 0 }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = cash, bank = 200000 }
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = vector3(PDM.x, PDM.y, PDM.z)
    end
    Mock.players[DEALER].PlayerData.job = { name = 'cardealer', type = 'none', onduty = true }
end

describe('free-use showroom', function()
    it('pays before the car, once per purchase', function()
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        assert_eq(money(BUYER).bank, 190000)
        assert_eq(count(vehicles), 1)
        assert_eq(first().citizenid, 'CID1')
    end)
    it('a buyer without the money gets no car', function()
        Mock.players[BUYER].PlayerData.money.bank = 50
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        assert_eq(count(vehicles), 0)
        assert_eq(money(BUYER).bank, 50)
    end)
    it('only cars that shop sells, only at the shop', function()
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'cognoscenti' }) -- a dealer-only car
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'not_a_car' })
        Mock.coords[BUYER] = vector3(0, 0, 0)
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        assert_eq(count(vehicles), 0)
        assert_eq(money(BUYER).bank, 200000)
    end)
end)

describe('finance', function()
    it('checks the terms and stores them in the right columns', function()
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, 2000, 0, 'blista')     -- no payments
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, nil, 10, 'blista')     -- no down payment
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, 500, 10, 'blista')     -- below the minimum down
        assert_eq(count(vehicles), 0)
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, 2000, 8, 'blista')
        local car = first()
        assert_eq(money(BUYER).bank, 198000)
        assert_eq(car.balance, 8000)
        assert_eq(car.paymentamount, 1000)
        assert_eq(car.paymentsleft, 8)
    end)
    it('a payment lowers the balance once and keeps the columns straight', function()
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, 2000, 8, 'blista')
        local car = first()
        Mock.fireNet('qb-vehicleshop:server:financePayment', BUYER, 1000, { vehiclePlate = car.plate })
        assert_eq(car.balance, 7000)
        assert_eq(car.paymentsleft, 7)
        assert_eq(car.paymentamount, 1000)
        assert_eq(money(BUYER).bank, 197000)
    end)
    it('paying off takes the balance once', function()
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, 2000, 8, 'blista')
        local car = first()
        Mock.fireNet('qb-vehicleshop:server:financePaymentFull', BUYER, { vehPlate = car.plate })
        Mock.fireNet('qb-vehicleshop:server:financePaymentFull', BUYER, { vehPlate = car.plate })
        assert_eq(car.balance, 0)
        assert_eq(money(BUYER).bank, 190000)
    end)
end)

describe('dealer sales', function()
    local function atLuxury() for _, src in ipairs({ BUYER, DEALER, STRANGER }) do Mock.coords[src] = vector3(LUX.x, LUX.y, LUX.z) end end

    it('charge the customer only after they accept', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        assert_eq(money(BUYER).bank, 200000)        -- nothing taken yet
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:confirmPurchase'), 1)
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true)
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true) -- a repeated answer
        assert_eq(money(BUYER).bank, 100000)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000)
        assert_eq(money(DEALER).bank, 200000 + 100000 * Config.Commission)
        assert_eq(count(vehicles), 1)
    end)
    it('a declined offer costs nothing', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, false)
        assert_eq(money(BUYER).bank, 200000)
        assert_eq(count(vehicles), 0)
    end)
    it('only the dealership staff can sell', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', STRANGER, 'cognoscenti', BUYER)
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true)
        assert_eq(money(BUYER).bank, 200000)
        assert_eq(money(STRANGER).bank, 200000)
    end)
    it('a financed dealer sale takes the down payment after acceptance', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellfinanceVehicle', DEALER, 20000, 10, 'cognoscenti', BUYER)
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true)
        assert_eq(money(BUYER).bank, 180000)
        assert_eq(first().balance, 80000)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000)
    end)
end)

describe('/transfervehicle', function()
    local function sellerInCar()
        vehicles['MYCAR1'] = { citizenid = 'CID3', vehicle = 'blista', plate = 'MYCAR1', balance = 0 }
        Mock.vehicleOf[STRANGER] = 900
        Mock.plates[900] = 'MYCAR1'
    end
    it('a paid transfer waits for the buyer and moves the money once', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        assert_eq(money(BUYER).bank, 200000)
        assert_eq(vehicles.MYCAR1.citizenid, 'CID3')
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true)
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true)
        assert_eq(money(BUYER).bank, 195000)
        assert_eq(money(STRANGER).bank, 205000)
        assert_eq(vehicles.MYCAR1.citizenid, 'CID1')
    end)
    it('a buyer who declines keeps their money', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, false)
        assert_eq(money(BUYER).bank, 200000)
        assert_eq(vehicles.MYCAR1.citizenid, 'CID3')
    end)
end)
