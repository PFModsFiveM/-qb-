-- pfm-vehiclesales (used car lot) on the ledger: the buyer pays once, one buyer per car, the seller is
-- paid once (online or offline), and a car sold back is paid once.
load_resource('tests/lua/ledger_env.lua')

QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 20000, hash = 'h_sultan' } }

local listings = {}   -- occasion_vehicles
local owned = {}      -- player_vehicles: [plate] = row

FakeDB.extraPatterns = {
    { 'SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', function(p)
        local l = listings[p[1]]
        return (l and l.occasionid == p[2]) and { l } or {}
    end },
    { 'DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', function(p)
        local l = listings[p[1]]
        if l and l.occasionid == p[2] then listings[p[1]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    -- the statements the old code used for an offline seller
    { 'SELECT * FROM players WHERE citizenid = ?', function(p)
        local row = FakeDB.players[p[1]]
        return row and { { citizenid = p[1], money = json.encode(row.money) } } or {}
    end },
    { 'UPDATE players SET money = ? WHERE citizenid = ?', function(p) FakeDB.players[p[2]] = { money = json.decode(p[1]) }; return 1 end },
    { 'INSERT INTO player_vehicles', function(p) owned[p[6]] = { citizenid = p[2], vehicle = p[3], hash = p[4], plate = p[6] }; return 1 end },
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? and hash = ?', function(p)
        local v = owned[p[1]]
        if v and v.citizenid == p[2] and v.hash == p[3] then owned[p[1]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
}

LedgerEnv.load('pfm-vehiclesales', { 'pfm-vehiclesales/config.lua', 'pfm-vehiclesales/server/main.lua' })
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }

local BUYER, BUYER2, SELLER = 1, 2, 3
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local CAR = { plate = 'USED123', oid = 'OC1234' }

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    later()
    for src, money in pairs({ [BUYER] = 20000, [BUYER2] = 20000, [SELLER] = 0 }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = money }
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = LOT
    end
    listings = { [CAR.plate] = { seller = 'CID3', price = 10000, plate = CAR.plate, occasionid = CAR.oid, model = 'sultan', mods = '{}' } }
    owned = {}
end

describe('buying a used car', function()
    it('the buyer pays once and the seller gets 77 %', function()
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, CAR)
        -- no tax in tests (pf-government does not answer), so any tax would have come back
        assert_eq(bank(BUYER), 10000)
        assert_eq(bank(SELLER), 7700)
        assert_eq(owned[CAR.plate].citizenid, 'CID1')
        later()
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, CAR) -- the listing is gone
        assert_eq(bank(BUYER), 10000)
        assert_eq(bank(SELLER), 7700)
    end)
    it('an offline seller is paid through the ledger', function()
        Mock.players[SELLER] = nil
        FakeDB.players['CID3'] = { money = { cash = 0, bank = 5 } }
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, CAR)
        assert_eq(FakeDB.players['CID3'].money.bank, 7705)
    end)
    it('a buyer without the money gets nothing and the listing stays', function()
        Mock.players[BUYER].PlayerData.money.bank = 500
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, CAR)
        assert_eq(bank(BUYER), 500)
        assert_eq(owned[CAR.plate], nil)
        assert_true(listings[CAR.plate] ~= nil)
        assert_eq(bank(SELLER), 0)
    end)
    it('when the car is gone after paying, the buyer is refunded', function()
        -- the listing disappears between the lookup and the claim (another buyer won it)
        local claimPattern = FakeDB.extraPatterns[2]
        local original = claimPattern[2]
        claimPattern[2] = function() return { affectedRows = 0 } end
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER2, CAR)
        claimPattern[2] = original
        assert_eq(bank(BUYER2), 20000)
        assert_eq(owned[CAR.plate], nil)
        assert_eq(bank(SELLER), 0)
    end)
    it('a seller cannot buy their own listing', function()
        Mock.players[SELLER].PlayerData.money.bank = 20000
        Mock.fireNet('qb-occasions:server:buyVehicle', SELLER, CAR)
        assert_eq(bank(SELLER), 20000)
        assert_true(listings[CAR.plate] ~= nil)
    end)
end)

describe('selling a car back', function()
    it('pays half the catalog price once', function()
        owned['MINE1'] = { citizenid = 'CID1', vehicle = 'sultan', hash = 'h_sultan', plate = 'MINE1' }
        Mock.fireNet('qb-occasions:server:sellVehicleBack', BUYER, { plate = 'MINE1', model = 'h_sultan' })
        later()
        Mock.fireNet('qb-occasions:server:sellVehicleBack', BUYER, { plate = 'MINE1', model = 'h_sultan' })
        assert_eq(bank(BUYER), 30000)
        assert_eq(#LedgerEnv.paid('pfm-vehiclesales:sellback:'), 1)
    end)
end)
