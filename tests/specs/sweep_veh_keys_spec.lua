-- pfm-vehiclekeys: keys to and locks of another player's own car need its keys, its driver's seat or
-- (to unlock) a lockpick; keys are handed to people nearby; server grants work. pfm-fuel: the
-- player-loaded hook is server-only.
load_resource('tests/lua/fivem_mocks.lua')

local owners = {}   -- player_vehicles: [plate] = citizenid
MySQL.scalar = setmetatable({ await = function(_, p) return owners[p[1]] end }, { __call = function() end })
function GetEntityType() return 2 end
local locked = {}
function SetVehicleDoorsLocked(veh, state) locked[#locked + 1] = { veh = veh, state = state } end
local items = {}    -- [src] = { name = true }
Mock.exportsByResource['pfm-inventory'] = { GetItemByName = function(_, src, name) return items[src] and items[src][name] and { name = name } or nil end }

Config = nil
load_resource('pfm-vehiclekeys/config.lua')
load_resource('pfm-vehiclekeys/server/main.lua')

local OWNER, THIEF, FRIEND, FAR = 1, 2, 3, 4
local CAR = 50
local HERE = vector3(0, 0, 0)

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.vehicleOf, Mock.plates = {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    locked, items = {}, {}
    owners = { MYCAR123 = 'CID' .. OWNER }
    for _, src in ipairs({ OWNER, THIEF, FRIEND, FAR }) do
        Mock.newPlayer(src).PlayerData.metadata.vehicleKeys = {}
        Mock.coords[src] = HERE
    end
    Mock.coords[FAR] = vector3(800, 0, 0)
    for _, src in ipairs({ OWNER, THIEF, FRIEND, FAR }) do RemoveKeys(src, 'MYCAR123') end
    Mock.reset()
    Mock.coords[CAR] = HERE
    Mock.plates[CAR] = 'MYCAR123'
end

local function hasKeys(src) return Mock.players[src].PlayerData.metadata.vehicleKeys.MYCAR123 == true end

describe("another player's car", function()
    it('standing next to it gives no keys; sitting in the driver seat does', function()
        Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', THIEF, CAR)
        assert_false(hasKeys(THIEF))
        Mock.vehicleOf[THIEF] = CAR
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', THIEF, CAR)
        assert_true(hasKeys(THIEF))
    end)
    it('an NPC car nearby still gives keys (stolen from a driver, carjacked)', function()
        Mock.plates[CAR] = 'NPC00001'
        Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', THIEF, CAR)
        assert_true(Mock.players[THIEF].PlayerData.metadata.vehicleKeys.NPC00001 == true)
    end)
    it('cannot be unlocked without keys or a lockpick, nor locked without keys', function()
        Mock.fireNet('qb-vehiclekeys:server:setVehLockState', THIEF, CAR, 1)
        Mock.fireNet('qb-vehiclekeys:server:setVehLockState', THIEF, CAR, 2)
        assert_eq(#locked, 0)
        items[THIEF] = { lockpick = true }
        Mock.fireNet('qb-vehiclekeys:server:setVehLockState', THIEF, CAR, 1)
        assert_eq(#locked, 1)
        Mock.fireNet('qb-vehiclekeys:server:setVehLockState', OWNER, CAR, 2) -- the owner's own car
        assert_eq(#locked, 2)
    end)
end)

describe('giving keys', function()
    it('a key holder gives keys to someone nearby, not across the map', function()
        GiveKeys(OWNER, 'MYCAR123')
        Mock.fireNet('qb-vehiclekeys:server:GiveVehicleKeys', OWNER, FAR, 'MYCAR123')
        assert_false(Mock.players[FAR].PlayerData.metadata.vehicleKeys.MYCAR123 == true)
        Mock.fireNet('qb-vehiclekeys:server:GiveVehicleKeys', OWNER, FRIEND, 'MYCAR123')
        assert_true(hasKeys(FRIEND))
    end)
    it('a server script can grant keys (pf-jobs triggers this event from the server)', function()
        source = ''
        Mock.netHandlers['qb-vehiclekeys:server:GiveVehicleKeys'](FRIEND, 'JOBCAR01')
        source = nil
        assert_true(Mock.players[FRIEND].PlayerData.metadata.vehicleKeys.JOBCAR01 == true)
    end)
end)

describe('pfm-fuel', function()
    it('the player-loaded hook is not a net event', function()
        QBCore = nil
        Mock.netHandlers['QBCore:Server:PlayerLoaded'] = nil
        Config = nil
        load_resource('pfm-fuel/config.lua')
        load_resource('pfm-fuel/server/main.lua')
        load_resource('pfm-fuel/server/pricing.lua')
        assert_eq(Mock.netHandlers['QBCore:Server:PlayerLoaded'], nil)
        assert_true(Mock.eventHandlers['QBCore:Server:PlayerLoaded'] ~= nil)
    end)
end)
