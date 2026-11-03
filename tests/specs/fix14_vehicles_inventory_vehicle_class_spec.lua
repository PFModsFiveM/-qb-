-- pfm-inventory trunk and glovebox sizes (fix14 CLASS-1): the class comes from the car's model on
-- the server (pfm-core's vehicle list: category -> class), not from the class the client names. An
-- executor in a compact answered 12 (vans) or 20 (commercial) and got a van's or truck's trunk. A
-- model the list does not know (an ambient car) gets the client's class, never above the default.
load_resource('tests/lua/fivem_mocks.lua')
QBCoreMock.Shared.Vehicles = {
    blista = { name = 'Blista', category = 'compacts', hash = joaat('blista') },
    speedo = { name = 'Speedo', category = 'vans', hash = joaat('speedo') },
    sanchez = { name = 'Sanchez', category = 'motorcycles' },               -- no hash: from the model name
}
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/vehicles.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

local vehicleAnswer = {}
QBCoreMock.Functions.TriggerClientCallback = function(_, _, cb) cb(vehicleAnswer[1], vehicleAnswer[2]) end
load_resource('pfm-inventory/server/commands.lua')

Mock.vehicles = {}
function GetAllVehicles() return Mock.vehicles end
function GetVehicleDoorLockStatus() return 1 end

local P = 1
local CAR = 601

local function openedStorage()
    local ev = Mock.clientEventsNamed('qb-inventory:client:openInventory')
    for i = #ev, 1, -1 do if ev[i].target == P and ev[i].args[2] then return ev[i].args[2] end end
end
--- the player at the trunk of a car of `model` (a hash), the client naming `class`
local function atTrunk(plate, model, class)
    Mock.vehicles = { CAR }
    Mock.plates[CAR], Mock.models[CAR] = plate, model
    Mock.coords[CAR] = vector3(2, 0, 0)
    vehicleAnswer = { 'trunk-' .. plate, class }
end
local function inventoryKey()
    Player(P).state.inv_busy = false
    Mock.rawCommands['inventory'](P)
    return openedStorage()
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    for k in pairs(Inventories) do Inventories[k] = nil end
    Mock.newPlayer(P)
    Mock.coords = { [P] = vector3(0, 0, 0) }
    Mock.vehicles, Mock.plates, Mock.vehicleOf, Mock.models = {}, {}, {}, {}
end

describe('fix14 CLASS-1: the size of a trunk', function()
    it('a compact answered as a van or a truck opens with a compact\'s trunk', function()
        atTrunk('CMP001', GetHashKey('blista'), 12)
        local inv = inventoryKey()
        assert_true(inv ~= nil, 'opened')
        assert_eq(inv.maxweight, VehicleStorage[0].trunkWeight)
        assert_eq(inv.slots, VehicleStorage[0].trunkSlots)
        Inventories['trunk-CMP001'] = nil
        atTrunk('CMP001', GetHashKey('blista'), 20)
        assert_eq(inventoryKey().maxweight, VehicleStorage[0].trunkWeight)
    end)

    it('a van is a van whatever the client says (the model hash signed or unsigned)', function()
        atTrunk('VAN001', GetHashKey('speedo'), 0)
        assert_eq(inventoryKey().maxweight, VehicleStorage[12].trunkWeight)
        Inventories['trunk-VAN001'] = nil
        atTrunk('VAN001', joaat('speedo'), 0)
        assert_eq(inventoryKey().maxweight, VehicleStorage[12].trunkWeight)
    end)

    it('a vehicle listed without a hash is found by its model name', function()
        atTrunk('BIKE01', GetHashKey('sanchez'), 12)
        assert_eq(inventoryKey().maxweight, VehicleStorage[8].trunkWeight)
    end)

    it('a model the list does not know: the client\'s class, never more than the default', function()
        atTrunk('NPC001', GetHashKey('someambientcar'), 12)
        local inv = inventoryKey()
        assert_eq(inv.maxweight, math.min(VehicleStorage[12].trunkWeight, VehicleStorage.default.trunkWeight))
        assert_eq(inv.slots, math.min(VehicleStorage[12].trunkSlots, VehicleStorage.default.trunkSlots))
        Inventories['trunk-NPC001'] = nil
        atTrunk('NPC001', GetHashKey('someambientcar'), 0)
        assert_eq(inventoryKey().maxweight, VehicleStorage[0].trunkWeight, 'a smaller class stays smaller')
        Inventories['trunk-NPC001'] = nil
        atTrunk('NPC001', GetHashKey('someambientcar'), 'x')
        assert_eq(inventoryKey().maxweight, VehicleStorage.default.trunkWeight)
    end)
end)

describe('fix14 CLASS-1: the size of a glovebox', function()
    it('comes from the model of the car the player sits in', function()
        -- (the shipped config gives every class the same glovebox; make two differ)
        local bike, truck = VehicleStorage[8], VehicleStorage[20]
        VehicleStorage[8] = { gloveboxSlots = 2, gloveboxWeight = 3000, trunkSlots = bike.trunkSlots, trunkWeight = bike.trunkWeight }
        VehicleStorage[20] = { gloveboxSlots = 9, gloveboxWeight = 25000, trunkSlots = truck.trunkSlots, trunkWeight = truck.trunkWeight }
        Mock.vehicles = { CAR }
        Mock.plates[CAR], Mock.models[CAR] = 'BIKE02', GetHashKey('sanchez')
        Mock.vehicleOf[P] = CAR
        vehicleAnswer = { 'glovebox-BIKE02', 20 }
        local inv = inventoryKey()
        VehicleStorage[8], VehicleStorage[20] = bike, truck
        assert_eq(inv.name, 'glovebox-BIKE02')
        assert_eq(inv.maxweight, 3000)
        assert_eq(inv.slots, 2)
    end)
end)
