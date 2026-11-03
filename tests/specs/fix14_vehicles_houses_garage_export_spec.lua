-- pfm-houses (fix14 GAR-1): a garage a real estate agent places goes to pfm-garages on the server
-- (exports SetHouseGarage), with only its position and heading; pfm-garages no longer takes house
-- garages from clients. A stranger, a position away from the agent or a NaN position changes nothing.
load_resource('tests/lua/ledger_env.lua')

CancelEvent = CancelEvent or function() end
QBCoreMock.Commands.Add = function() end

local DOOR = vector3(100.0, 200.0, 30.0)
local HOUSE = 'Garage Way1'
local writes = {}
FakeDB.extraPatterns = {
    { 'UPDATE houselocations SET garage = ?', function(p) writes[#writes + 1] = p return 1 end },
}
local garageCalls = {}
Mock.exportsByResource['pfm-garages'] = {
    SetHouseGarage = function(_, house, label, coords) garageCalls[#garageCalls + 1] = { house = house, label = label, coords = coords } return true end,
}
LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua' })

local AGENT, STRANGER = 1, 2
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    writes, garageCalls = {}, {}
    Config.Houses = { [HOUSE] = { coords = { enter = { x = DOOR.x, y = DOOR.y, z = DOOR.z, h = 0.0 } }, price = 1000, adress = 'Garage Way 1', tier = 1, locked = true, garage = {} } }
    Mock.newPlayer(AGENT).PlayerData.job = { name = 'realestate' }
    Mock.newPlayer(STRANGER)
    Mock.coords[AGENT], Mock.coords[STRANGER] = DOOR, DOOR
end

local function addGarage(src, coords) Mock.fireNet('qb-houses:server:addGarage', src, HOUSE, coords) end

describe('a house garage placed by an agent', function()
    it('goes to pfm-garages on the server, with only its position and heading', function()
        addGarage(AGENT, { x = DOOR.x + 2, y = DOOR.y, z = DOOR.z, w = 45, junk = string.rep('x', 5000) })
        assert_eq(#garageCalls, 1)
        local call = garageCalls[1]
        assert_eq(call.house, HOUSE)
        assert_eq(call.label, 'Garage Way 1')
        assert_eq(call.coords.x, DOOR.x + 2)
        assert_eq(call.coords.w, 45)
        assert_eq(call.coords.junk, nil)
        assert_eq(#writes, 1)
        assert_false(writes[1][1]:find('junk', 1, true) ~= nil, 'the stored JSON holds only the position')
        assert_eq(Config.Houses[HOUSE].garage.x, DOOR.x + 2, 'the server copy of the house knows its garage')
        local sent = Mock.clientEventsNamed('qb-garages:client:addHouseGarage')
        assert_eq(#sent, 1)
        assert_eq(sent[1].args[2].takeVehicle.junk, nil)
    end)
    it('a heading that is not a number becomes 0', function()
        addGarage(AGENT, { x = DOOR.x, y = DOOR.y, z = DOOR.z, w = 0 / 0 })
        assert_eq(garageCalls[1].coords.w, 0.0)
    end)
    it('a stranger, a position away from the agent or a NaN position changes nothing', function()
        addGarage(STRANGER, { x = DOOR.x, y = DOOR.y, z = DOOR.z, w = 0 })
        addGarage(AGENT, { x = DOOR.x + 50, y = DOOR.y, z = DOOR.z, w = 0 })
        addGarage(AGENT, { x = 0 / 0, y = DOOR.y, z = DOOR.z, w = 0 })
        addGarage(AGENT, 'nope')
        assert_eq(#garageCalls, 0)
        assert_eq(#writes, 0)
    end)
end)
