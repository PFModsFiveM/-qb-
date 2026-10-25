-- pfm-inventory: giving an item hands over the server's stack (never the client's info), and the
-- inventory key opens only the vehicle storage the player is really at.
load_resource('tests/lua/fivem_mocks.lua')
QBCoreMock.Shared.Items.markedbills = { name = 'markedbills', label = 'Marked Money', weight = 1000, type = 'item', unique = true, useable = false, image = 'markedbills.png' }
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/vehicles.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

-- the inventory key asks the client which vehicle storage it is at
local vehicleAnswer = {}
QBCoreMock.Functions.TriggerClientCallback = function(_, _, cb) cb(vehicleAnswer[1], vehicleAnswer[2]) end
load_resource('pfm-inventory/server/commands.lua')

-- server vehicle natives the mocks lack
Mock.vehicles = {}
Mock.lockStatus = {}
function GetAllVehicles() return Mock.vehicles end
function GetVehicleDoorLockStatus(veh) return Mock.lockStatus[veh] or 1 end

local GIVER, TAKER, FAR = 1, 2, 3
local CAR = 501

local function itemNamed(src, name)
    for _, item in pairs(Mock.players[src].PlayerData.items) do
        if item.name == name then return item end
    end
end

local function openedInventory(src)
    local ev = Mock.clientEventsNamed('qb-inventory:client:openInventory')
    for i = #ev, 1, -1 do if ev[i].target == src then return ev[i].args[2] end end
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    for k in pairs(Inventories) do Inventories[k] = nil end
    Mock.newPlayer(GIVER)
    Mock.newPlayer(TAKER)
    Mock.newPlayer(FAR)
    Mock.coords = { [GIVER] = vector3(0, 0, 0), [TAKER] = vector3(1, 0, 0), [FAR] = vector3(300, 0, 0) }
    Mock.vehicles, Mock.lockStatus, Mock.plates, Mock.vehicleOf = {}, {}, {}, {}
    for src in pairs(Mock.players) do Player(src).state.inv_busy = false end
    vehicleAnswer = {}
end

describe('giveItem', function()
    it("the receiver gets the giver's real item info, not the client's", function()
        assert_true(AddItem(GIVER, 'markedbills', 1, 1, { worth = 500 }))
        local ok = Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, 'markedbills', 1, 1, { worth = 99999999 })
        assert_true(ok, 'given')
        local got = itemNamed(TAKER, 'markedbills')
        assert_true(got, 'receiver has it')
        assert_eq(got.info.worth, 500, 'worth from the server copy')
        assert_eq(itemNamed(GIVER, 'markedbills'), nil, 'giver no longer has it')
    end)
    it('the slot must hold the named item', function()
        assert_true(AddItem(GIVER, 'lockpick', 1, 1))
        assert_true(AddItem(GIVER, 'goldbar', 1, 2))
        assert_false(Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, 'goldbar', 1, 1))
        assert_eq(itemNamed(TAKER, 'goldbar'), nil)
    end)
    it('bad amounts and item names are refused without a crash', function()
        assert_true(AddItem(GIVER, 'lockpick', 5, 1))
        assert_false(Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, 'lockpick', nil, 1))
        assert_false(Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, 'lockpick', -3, 1))
        assert_false(Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, 'lockpick', 6, 1))
        assert_false(Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, { 'lockpick' }, 1, 1))
        assert_eq(itemNamed(GIVER, 'lockpick').amount, 5)
    end)
    it('a player far away cannot be given to', function()
        assert_true(AddItem(GIVER, 'lockpick', 1, 1))
        assert_false(Mock.callCallback('qb-inventory:server:giveItem', GIVER, FAR, 'lockpick', 1, 1))
    end)
    it('a normal give still works', function()
        assert_true(AddItem(GIVER, 'lockpick', 3, 1))
        assert_true(Mock.callCallback('qb-inventory:server:giveItem', GIVER, TAKER, 'lockpick', 2, 1))
        assert_eq(itemNamed(TAKER, 'lockpick').amount, 2)
        assert_eq(itemNamed(GIVER, 'lockpick').amount, 1)
    end)
end)

describe('inventory key: vehicle storage', function()
    it('any stash id the client names is not opened', function()
        CreateInventory('policeevidence-trunk-1', { label = 'Evidence' })
        vehicleAnswer = { 'policeevidence-trunk-1', 0 }
        Mock.rawCommands['inventory'](GIVER)
        local opened = openedInventory(GIVER)
        assert_eq(opened, nil, 'only the own inventory opened')
        assert_eq(Inventories['policeevidence-trunk-1'].isOpen, false)
    end)
    it("a trunk of a car across the map is not opened", function()
        Mock.vehicles = { CAR }
        Mock.plates[CAR] = 'FAR123  '
        Mock.coords[CAR] = vector3(2000, 0, 0)
        vehicleAnswer = { 'trunk-FAR123  ', 0 }
        Mock.rawCommands['inventory'](GIVER)
        assert_eq(openedInventory(GIVER), nil)
    end)
    it("the trunk of the car right behind the player opens, a locked one does not", function()
        Mock.vehicles = { CAR }
        Mock.plates[CAR] = 'ABC123  '
        Mock.coords[CAR] = vector3(2, 0, 0)
        vehicleAnswer = { 'trunk-ABC123  ', 0 }
        Mock.rawCommands['inventory'](GIVER)
        local opened = openedInventory(GIVER)
        assert_true(opened, 'opened')
        assert_eq(opened.name, 'trunk-ABC123  ')
        Inventories['trunk-ABC123  '].isOpen = false
        Player(GIVER).state.inv_busy = false
        Mock.reset()
        Mock.lockStatus[CAR] = 2
        Mock.rawCommands['inventory'](GIVER)
        assert_eq(openedInventory(GIVER), nil, 'locked')
    end)
    it("the glovebox opens only for the car the player sits in", function()
        Mock.vehicles = { CAR }
        Mock.plates[CAR] = 'ABC123  '
        vehicleAnswer = { 'glovebox-ABC123  ', 0 }
        Mock.rawCommands['inventory'](GIVER)
        assert_eq(openedInventory(GIVER), nil, 'not in the car')
        Player(GIVER).state.inv_busy = false
        Mock.vehicleOf[GIVER] = CAR
        Mock.rawCommands['inventory'](GIVER)
        assert_eq(openedInventory(GIVER).name, 'glovebox-ABC123  ')
    end)
end)

describe('useItem', function()
    it("hooks see the server item's type, not the client's", function()
        local seen
        AddHook('ItemUsed', function(subtype) seen = subtype end)
        assert_true(AddItem(GIVER, 'weapon_pistol', 1, 1, { quality = 100 }))
        Mock.fireNet('qb-inventory:server:useItem', GIVER, { slot = 1, type = 'item' })
        assert_eq(seen, 'weapon', 'hooks are told the real item type')
    end)
end)
