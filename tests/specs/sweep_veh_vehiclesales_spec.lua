-- pfm-vehiclesales: taking a listing back returns the listed car (once), and the seller info callback
-- only gives the seller's name and contact details.
load_resource('tests/lua/ledger_env.lua')

local listings, owned, sellerRow = {}, {}, nil

FakeDB.extraPatterns = {
    { 'SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', function(p)
        local l = listings[p[1]]
        return (l and l.occasionid == p[2]) and { l } or {}
    end },
    { 'DELETE FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', function(p)
        local l = listings[p[2]]
        if l and l.occasionid == p[1] then listings[p[2]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'INSERT INTO player_vehicles', function(p) owned[#owned + 1] = { citizenid = p[2], vehicle = p[3], mods = p[5], plate = p[6] }; return 1 end },
    { 'FROM players WHERE citizenid = ?', function() return { sellerRow } end },
}

LedgerEnv.load('pfm-vehiclesales', { 'pfm-vehiclesales/config.lua', 'pfm-vehiclesales/server/main.lua' })

local SELLER, OTHER = 1, 2
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    for _, src in ipairs({ SELLER, OTHER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = LOT
    end
    listings = { CHEAP1 = { seller = 'CID1', price = 500, plate = 'CHEAP1', occasionid = 'OC1', model = 'blista', mods = '{"color":1}' } }
    owned = {}
    sellerRow = { citizenid = 'CID1', license = 'license:1', money = '{"bank":99999}', inventory = '[]', charinfo = '{"firstname":"Sam","lastname":"Seller","phone":"5551234","account":"PF1","birthdate":"1990-01-01"}' }
end

describe('taking a listing back', function()
    it('returns the car that was listed, whatever model the client names', function()
        Mock.fireNet('qb-occasions:server:ReturnVehicle', SELLER, { plate = 'CHEAP1', oid = 'OC1', model = 'adder', mods = '{"turbo":true}' })
        assert_eq(#owned, 1)
        assert_eq(owned[1].vehicle, 'blista')
        assert_eq(owned[1].mods, '{"color":1}')
    end)
    it('another player cannot take it', function()
        Mock.fireNet('qb-occasions:server:ReturnVehicle', OTHER, { plate = 'CHEAP1', oid = 'OC1', model = 'blista' })
        assert_eq(#owned, 0)
        assert_true(listings.CHEAP1 ~= nil)
    end)
end)

describe('seller information', function()
    it('only the name and contact details', function()
        local info = Mock.callCallback('qb-occasions:server:getSellerInformation', OTHER, 'CID1')
        assert_eq(info.money, nil)
        assert_eq(info.license, nil)
        assert_eq(info.inventory, nil)
        local ci = json.decode(info.charinfo)
        assert_eq(ci.firstname, 'Sam')
        assert_eq(ci.phone, '5551234')
        assert_eq(ci.birthdate, nil)
    end)
end)
