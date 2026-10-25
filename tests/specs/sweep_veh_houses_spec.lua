-- pfm-houses: stashes, the door, house transfer from the phone, key holders, locations and the
-- real estate tools are checked by the server.
load_resource('tests/lua/ledger_env.lua')

CancelEvent = CancelEvent or function() end
QBCoreMock.Commands.Add = function() end
QBCoreMock.Player = QBCoreMock.Player or {}

local DOOR = vector3(100.0, 200.0, 30.0)
local FAR = vector3(900.0, 900.0, 30.0)
local HOUSE, houseNo = nil, 0
local houses, playerHouses, playersRows = {}, {}, {}
local writes = {}
local opened = {}

local function record(name) return function(p) writes[#writes + 1] = { name = name, params = p }; return 1 end end

FakeDB.extraPatterns = {
    { 'SELECT owned FROM houselocations WHERE name = ?', function(p) local h = houses[p[1]]; return h and { { owned = h.owned } } or {} end },
    { 'UPDATE houselocations SET owned = ?', function(p) houses[p[2]] = houses[p[2]] or {}; houses[p[2]].owned = p[1]; return 1 end },
    { 'INSERT INTO player_houses', function(p) playerHouses[p[1]] = { house = p[1], identifier = p[2], citizenid = p[3], keyholders = p[4], stash = '{"x":1}' }; return 1 end },
    { 'SELECT * FROM player_houses WHERE house = ?', function(p) return playerHouses[p[1]] and { playerHouses[p[1]] } or {} end },
    { 'SELECT * FROM players WHERE citizenid = ? OR charinfo LIKE ?', function() return { { citizenid = 'CID1', charinfo = '{}' } } end },
    { 'SELECT * FROM players WHERE citizenid = ?', function(p) return playersRows[p[1]] and { playersRows[p[1]] } or {} end },
    { 'UPDATE player_houses SET citizenid = ?', record('transfer') },
    { 'UPDATE player_houses SET keyholders = ?', record('keys') },
    { 'UPDATE player_houses SET stash = ?', record('stash') },
    { 'INSERT INTO houselocations', record('newhouse') },
    { 'UPDATE houselocations SET garage = ?', record('garage') },
    { 'SELECT * FROM houselocations WHERE name LIKE ?', function() return nil end },
    { 'SELECT * FROM player_houses WHERE citizenid = ?', function(p) local out = {} for _, h in pairs(playerHouses) do if h.citizenid == p[1] then out[#out + 1] = h end end return out end },
}

LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua' })
MySQL.Sync = { fetchSingle = function(q, p) return MySQL.single.await(q, p) end }
Mock.exportsByResource['pfm-inventory'] = { OpenInventory = function(_, src, id) opened[#opened + 1] = { src = src, id = id } end }

local OWNER, GUEST, STRANGER, AGENT, COP = 1, 2, 3, 4, 5
local function newPlayer(src)
    local p = Mock.newPlayer(src)
    p.PlayerData.license = 'license:' .. src
    p.PlayerData.money = { cash = 0, bank = 1000000 }
    p.PlayerData.metadata.inside = { apartment = {} }
    Mock.coords[src] = DOOR
    return p
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    houseNo = houseNo + 1
    HOUSE = 'sweephouse' .. houseNo
    houses, playerHouses, writes, opened = { [HOUSE] = { owned = 0 } }, {}, {}, {}
    playersRows = { CID3 = { citizenid = 'CID3', license = 'license:3' } }
    Config.MinZOffset = 0
    Config.Houses = { [HOUSE] = { coords = { enter = { x = DOOR.x, y = DOOR.y, z = DOOR.z, h = 0.0 } }, price = 1000, adress = 'Test Street 1', tier = 1, locked = true } }
    newPlayer(OWNER)
    newPlayer(GUEST)
    newPlayer(STRANGER)
    newPlayer(AGENT).PlayerData.job = { name = 'realestate' }
    newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.fireNet('qb-houses:server:buyHouse', OWNER, HOUSE)
    assert(houses[HOUSE].owned == 1, 'setup: owner bought the house')
end

local function wrote(name)
    local n = 0
    for _, w in ipairs(writes) do if w.name == name then n = n + 1 end end
    return n
end

describe('house stash', function()
    it('a stranger cannot open a locked house stash, or any other stash id', function()
        Mock.fireNet('qb-houses:server:openStash', STRANGER, HOUSE)
        Mock.fireNet('qb-houses:server:openStash', STRANGER, 'policetrash')
        assert_eq(#opened, 0)
    end)
    it('the owner opens it from inside, not from across the map', function()
        Mock.coords[OWNER] = FAR
        Mock.fireNet('qb-houses:server:openStash', OWNER, HOUSE)
        assert_eq(#opened, 0)
        Mock.coords[OWNER] = DOOR
        Mock.fireNet('qb-houses:server:openStash', OWNER, HOUSE)
        assert_eq(#opened, 1)
        assert_eq(opened[1].id, HOUSE)
    end)
end)

describe('the door', function()
    it('nobody can be pulled into a house without ringing and being let in by someone inside', function()
        Mock.fireNet('qb-houses:server:OpenDoor', STRANGER, GUEST, HOUSE)
        Mock.fireNet('qb-houses:server:OpenDoor', OWNER, GUEST, HOUSE) -- the guest never rang
        assert_eq(#Mock.clientEventsNamed('qb-houses:client:SpawnInApartment'), 0)
    end)
    it('a visitor who rang is let in by the owner, and may then use the stash', function()
        Mock.fireNet('qb-houses:server:RingDoor', GUEST, HOUSE)
        Mock.fireNet('qb-houses:server:OpenDoor', OWNER, GUEST, HOUSE)
        local ev = Mock.clientEventsNamed('qb-houses:client:SpawnInApartment')
        assert_eq(#ev, 1)
        assert_eq(ev[1].target, GUEST)
        Mock.fireNet('qb-houses:server:openStash', GUEST, HOUSE)
        assert_eq(#opened, 1)
    end)
end)

describe('ownership and keys', function()
    it('only the owner can give the house away from the phone', function()
        assert_eq(Mock.callCallback('qb-phone:server:TransferCid', STRANGER, 'CID3', { name = HOUSE }), false)
        assert_eq(wrote('transfer'), 0)
        assert_eq(Mock.callCallback('qb-phone:server:TransferCid', OWNER, 'CID3', { name = HOUSE }), true)
        assert_eq(wrote('transfer'), 1)
    end)
    it('key holders and the owner id are only shown to the owner', function()
        assert_eq(Mock.callCallback('qb-houses:server:getHouseKeyHolders', STRANGER, HOUSE), nil)
        assert_eq(Mock.callCallback('qb-houses:server:getHouseOwner', STRANGER, HOUSE), nil)
        assert_eq(Mock.callCallback('qb-houses:server:getHouseOwner', OWNER, HOUSE), 'CID' .. OWNER)
    end)
    it('a key is only handed to someone standing next to the owner', function()
        Mock.coords[GUEST] = FAR
        Mock.fireNet('qb-houses:server:giveHouseKey', OWNER, GUEST, HOUSE)
        assert_eq(wrote('keys'), 0)
        Mock.coords[GUEST] = DOOR
        Mock.fireNet('qb-houses:server:giveHouseKey', OWNER, GUEST, HOUSE)
        assert_eq(wrote('keys'), 1)
    end)
    it('the locations callback does not hand out the owner license or key holders', function()
        local row = Mock.callCallback('qb-houses:server:getHouseLocations', STRANGER, HOUSE)
        assert_eq(row.identifier, nil)
        assert_eq(row.citizenid, nil)
        assert_eq(row.keyholders, nil)
        assert_eq(row.stash, '{"x":1}')
    end)
    it('a stranger cannot move the stash spot', function()
        Mock.fireNet('qb-houses:server:setLocation', STRANGER, { x = DOOR.x, y = DOOR.y, z = DOOR.z }, HOUSE, 1)
        assert_eq(wrote('stash'), 0)
        Mock.fireNet('qb-houses:server:setLocation', OWNER, { x = DOOR.x, y = DOOR.y, z = DOOR.z }, HOUSE, 1)
        assert_eq(wrote('stash'), 1)
    end)
    it('a stranger is not recorded as inside a locked house', function()
        Mock.fireNet('qb-houses:server:SetInsideMeta', STRANGER, HOUSE, true)
        assert_eq(Mock.players[STRANGER].PlayerData.metadata.inside.house, nil)
        Mock.fireNet('qb-houses:server:SetInsideMeta', OWNER, HOUSE, true)
        assert_eq(Mock.players[OWNER].PlayerData.metadata.inside.house, HOUSE)
    end)
end)

describe('real estate and police tools', function()
    it('only real estate agents create houses and garages', function()
        local coords = { enter = { x = DOOR.x, y = DOOR.y, z = DOOR.z, h = 0 } }
        Mock.fireNet('qb-houses:server:addNewHouse', STRANGER, 'Fake Street', coords, 1, 1)
        Mock.fireNet('qb-houses:server:addGarage', STRANGER, HOUSE, { x = DOOR.x, y = DOOR.y, z = DOOR.z, w = 0 })
        assert_eq(wrote('newhouse'), 0)
        assert_eq(wrote('garage'), 0)
        Mock.fireNet('qb-houses:server:addNewHouse', AGENT, 'Real Street', coords, 250000, 1)
        Mock.fireNet('qb-houses:server:addGarage', AGENT, HOUSE, { x = DOOR.x, y = DOOR.y, z = DOOR.z, w = 0 })
        assert_eq(wrote('newhouse'), 1)
        assert_eq(wrote('garage'), 1)
    end)
    it('the MEOS house search is for police', function()
        assert_eq(Mock.callCallback('qb-phone:server:MeosGetPlayerHouses', STRANGER, 'Test'), nil)
        local res = Mock.callCallback('qb-phone:server:MeosGetPlayerHouses', COP, 'Test')
        assert_eq(type(res), 'table')
    end)
end)
