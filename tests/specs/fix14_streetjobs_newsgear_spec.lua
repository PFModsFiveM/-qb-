-- Batch 14 (newsjob-gear-per-plate): the news camera, mic and boom mic are issued per reporter, not
-- per van. A new van's trunk used to be stocked again for every new plate, so a reporter could take
-- the gear out, store the van, ask again 10 s later and repeat forever. Now player metadata
-- 'newsgear' records what was issued; the trunk only gets what the reporter was not issued and does
-- not carry; storing the van, going off duty and leaving the job hand the gear back (from the trunk
-- and the reporter); gear not handed back blocks a new issue for Config.GearResetHours.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-newsjob' end
Config = nil
load_resource('pfm-newsjob/config.lua')

-- the inventories: trunks by id, what each player carries by item
local trunks, carried = {}, {}
local function trunkCount(id, name)
    local n = 0
    for _, it in pairs((trunks[id] or {}).items or {}) do if it.name == name then n = n + it.amount end end
    return n
end
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function(_, id) trunks[id] = trunks[id] or { items = {} } end,
    AddItem = function(_, id, name, amount, slot)
        trunks[id].items[slot or (#trunks[id].items + 1)] = { name = name, amount = amount or 1, slot = slot }
        return true
    end,
    RemoveInventory = function(_, id) trunks[id] = nil end,
    GetInventory = function(_, id) return trunks[id] end,
    GetItemCount = function(_, src, name) return (carried[src] or {})[name] or 0 end,
    RemoveItem = function(_, src, name, n)
        local have = (carried[src] or {})[name] or 0
        if have < (n or 1) then return false end
        carried[src][name] = have - (n or 1)
        return true
    end,
}
Mock.exportsByResource['pfm-vehiclekeys'] = { HasKeys = function() return true end }

local alive, nextVeh = {}, 7000
function DoesEntityExist(e) return alive[e] == true end
function GetVehicleEngineHealth() return 1000.0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
local realDelete = DeleteEntity
function DeleteEntity(e) alive[e] = nil; return realDelete(e) end
QBCoreMock.Functions.SpawnVehicle = function(src, model, coords, warp)
    nextVeh = nextVeh + 1
    alive[nextVeh] = true
    Mock.coords[nextVeh] = vector3(coords.x, coords.y, coords.z)
    if warp then Mock.vehicleOf[src] = nextVeh end
    return nextVeh
end

load_resource('pfm-newsjob/server/main.lua')

local REP = 1
local GEAR = { 'newscam', 'newsmic', 'newsbmic' }
local VAN = Config.Locations.vehicle.coords
local function at(e, c) Mock.coords[e] = vector3(c.x, c.y, c.z) end
local function lastPlate()
    local list = Mock.clientEventsNamed('pfm-newsjob:client:spawnVehicle')
    return list[#list] and list[#list].args[3]
end
local function takeVan()
    Mock.clock = Mock.clock + 60
    at(REP, VAN)
    assert_true(NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo'), 'van issued')
    return 'trunk-' .. lastPlate()
end
-- the reporter moves every piece from the trunk to their pockets
local function emptyTrunk(id)
    for slot, it in pairs(trunks[id].items) do
        carried[REP][it.name] = (carried[REP][it.name] or 0) + it.amount
        trunks[id].items[slot] = nil
    end
end
local function store()
    assert_true(NewsJob.StoreVehicle(REP), 'stored')
end
local function inPockets()
    local n = 0
    for _, name in ipairs(GEAR) do n = n + (carried[REP][name] or 0) end
    return n
end
local function inTrunk(id)
    local n = 0
    for _, name in ipairs(GEAR) do n = n + trunkCount(id, name) end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}, {}, {}
    trunks, carried, alive = {}, { [REP] = {} }, {}
    NewsJob.__reset()
    Mock.clock = Mock.clock + 100000
    local p = Mock.newPlayer(REP, 'CIDREP')
    p.PlayerData.job = { name = 'reporter', grade = { level = 0 }, onduty = true }
    p.Functions.SetJobDuty = function(onduty) p.PlayerData.job.onduty = onduty end
end

describe('fix14 newsjob: gear is issued per reporter, not per van', function()
    it('gear moved out of the van is not stocked again in the next van', function()
        local first = takeVan()
        assert_eq(inTrunk(first), 3, 'the first van carries the gear')
        -- the reporter puts the gear away somewhere else (a stash), then stores the van and asks again
        emptyTrunk(first)
        carried[REP] = {}
        store()
        for _ = 1, 5 do
            local again = takeVan()
            assert_eq(inTrunk(again), 0, 'no new gear while the first set is still out')
            store()
        end
    end)

    it('storing the van hands the gear back: the trunk and the pockets', function()
        local first = takeVan()
        emptyTrunk(first)
        assert_eq(inPockets(), 3)
        store()
        assert_eq(inPockets(), 0, 'the carried gear was handed back with the van')
        local again = takeVan()
        assert_eq(inTrunk(again), 3, 'handed back, so the next van has it again')
    end)

    it('gear left in the trunk goes back with the van', function()
        takeVan()
        store()
        assert_eq(inTrunk(takeVan()), 3)
    end)

    it('a reporter who still carries a piece does not get a second one', function()
        local first = takeVan()
        emptyTrunk(first)
        Mock.fireEvent('entityRemoved', nil, Mock.vehicleOf[REP]) -- the van was cleaned up, not stored
        Mock.vehicleOf[REP] = nil
        local again = takeVan()
        assert_eq(inTrunk(again), 0)
        assert_eq(inPockets(), 3, 'still the one set')
    end)

    it('going off duty and leaving the job hand the carried gear back', function()
        local first = takeVan()
        emptyTrunk(first)
        at(REP, Config.Locations.duty.coords)
        assert_true(NewsJob.ToggleDuty(REP))
        assert_eq(inPockets(), 0, 'off duty: handed in')
        -- on duty again, a new set; then leaving the job takes it back too
        Mock.clock = Mock.clock + 10
        assert_true(NewsJob.ToggleDuty(REP))
        store()
        local again = takeVan()
        assert_eq(inTrunk(again), 3)
        emptyTrunk(again)
        Mock.players[REP].PlayerData.job = { name = 'unemployed' }
        TriggerEvent('QBCore:Server:OnJobUpdate', REP, { name = 'unemployed' })
        assert_eq(inPockets(), 0, 'left the job: handed in')
    end)

    it('gear never handed back can be issued again after the reset time, or by a reset', function()
        local first = takeVan()
        emptyTrunk(first)
        carried[REP] = {}
        store()
        assert_eq(inTrunk(takeVan()), 0)
        store()
        Mock.clock = Mock.clock + Config.GearResetHours * 3600 + 1
        assert_eq(inTrunk(takeVan()), 3, 'issued again after the reset time')
        emptyTrunk('trunk-' .. lastPlate())
        carried[REP] = {}
        store()
        assert_eq(inTrunk(takeVan()), 0)
        store()
        assert_true(Mock.selfExport('ResetReporterGear')(REP))
        assert_eq(inTrunk(takeVan()), 3, 'issued again after a reset')
    end)
end)
