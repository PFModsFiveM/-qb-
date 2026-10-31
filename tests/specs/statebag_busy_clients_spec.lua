-- sv_stateBagStrictMode, client side of `inv_busy`: pfm-weed, pfm-drugs (corner selling),
-- pfm-smallresources (harness) and pfm-diving used to set the replicated flag themselves. They
-- now ask pfm-inventory's server to hold or release an action lock (checked and set there, see
-- statebag_inventory_busy_spec.lua), and never write a state bag.
load_resource('tests/lua/fivem_mocks.lua')

-- ── client mocks ──────────────────────────────────────────────────
local toServer, stateWrites, bars, callbackResults, targetOptions = {}, {}, {}, {}, {}
local inVehicle = false
function TriggerServerEvent(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end
local function bag()
    return setmetatable({}, { __index = { set = function(_, k, v, r) stateWrites[#stateWrites + 1] = { key = k, value = v, replicated = r } end } })
end
LocalPlayer = { state = bag() }
function Entity() return { state = bag() } end
function PlayerPedId() return 1 end
function GetOffsetFromEntityInWorldCoords() return vector3(1.0, 2.0, 3.0) end
function IsPedInAnyVehicle() return inVehicle end
function GetVehiclePedIsUsing() return 50 end
function GetVehicleClass() return 0 end
function HasModelLoaded() return true end
function CreatePed() return 77 end
QBCoreMock.Functions.Progressbar = function(name, _, _, _, _, _, _, _, _, onFinish, onCancel)
    bars[#bars + 1] = { name = name, finish = onFinish, cancel = onCancel }
end
QBCoreMock.Functions.TriggerCallback = function(name, cb)
    local r = callbackResults[name]
    if r then cb(table.unpack(r)) end
end
Mock.exportsByResource['pfm-target'] = {
    AddBoxZone = function() end,
    RemoveZone = function() end,
    AddTargetEntity = function(_, _, opts) targetOptions[#targetOptions + 1] = opts end,
}
QBCore = QBCoreMock

-- every other native a client file calls while loading: a no-op
local NOT_NATIVES = { Config = true, QBWeed = true, BoxZone = true, ComboZone = true, PolyZone = true }
setmetatable(_G, { __index = function(_, k)
    if type(k) == 'string' and not NOT_NATIVES[k] and k:match('^%u%l') then return function() return nil end end
end })

-- Each FiveM resource runs in its own Lua state (its own Config): load each in its own environment.
local function loadResource(files, setup)
    local env = setmetatable({}, { __index = _G })
    for i, f in ipairs(files) do
        assert(load(__readfile(f), '@' .. f, 't', env))()
        if i == 1 and setup then setup(env) end
    end
    return env
end
local function useTarget(env) env.Config.UseTarget = true end
loadResource({ 'pfm-weed/config.lua', 'pfm-weed/client/main.lua' })
loadResource({ 'pfm-drugs/config.lua', 'pfm-drugs/client/cornerselling.lua' }, useTarget)
loadResource({ 'pfm-smallresources/config.lua', 'pfm-smallresources/client/seatbelt.lua' })
local diving = loadResource({ 'pfm-diving/config.lua', 'pfm-diving/client/main.lua' }, useTarget)
local divingLoaded = Mock.netHandlers['QBCore:Client:OnPlayerLoaded']

local function busyCalls()
    local out = {}
    for _, e in ipairs(toServer) do
        if e.name == 'qb-inventory:server:setActionBusy' then out[#out + 1] = e.args[1] .. '=' .. tostring(e.args[2]) end
    end
    return table.concat(out, ' ')
end
local function lastBar() return bars[#bars] end

BeforeEach = function()
    Mock.reset()
    toServer, stateWrites, bars, targetOptions = {}, {}, {}, {}
    inVehicle = false
end

describe('pfm-weed', function()
    it('planting holds the lock for the whole progress bar, then releases it', function()
        callbackResults['qb-weed:server:getBuildingPlants'] = { {} }
        Mock.fireNet('qb-weed:client:getHousePlants', 1, 'house1')
        Mock.fireNet('qb-weed:client:placePlant', 1, 'ogkush')
        assert_eq(busyCalls(), 'weed=true', 'held while the bar runs (it used to be released at once)')
        lastBar().finish()
        assert_eq(busyCalls(), 'weed=true weed=false')
        assert_eq(toServer[#toServer].name, 'qb-weed:server:placePlant')
        assert_eq(#stateWrites, 0, 'no state bag written')
    end)

    it('a cancelled planting releases the lock and plants nothing', function()
        callbackResults['qb-weed:server:getBuildingPlants'] = { {} }
        Mock.fireNet('qb-weed:client:getHousePlants', 1, 'house1')
        Mock.fireNet('qb-weed:client:placePlant', 1, 'ogkush')
        lastBar().cancel()
        assert_eq(busyCalls(), 'weed=true weed=false')
        assert_eq(#stateWrites, 0)
    end)
end)

describe('pfm-drugs corner selling', function()
    it('selling holds the lock until it stops', function()
        Mock.fireNet('police:SetCopCount', 1, 5)
        callbackResults['qb-drugs:server:cornerselling:getAvailableDrugs'] = { { { item = 'weed_brick', amount = 1 } } }
        Mock.fireNet('qb-drugs:client:cornerselling', 1)
        assert_eq(busyCalls(), 'cornerselling=true')
        Mock.fireNet('qb-drugs:client:cornerselling', 1)                     -- toggled off
        assert_eq(busyCalls(), 'cornerselling=true cornerselling=false')
        assert_eq(#stateWrites, 0)
    end)

    it('running out of drugs releases it', function()
        Mock.fireNet('police:SetCopCount', 1, 5)
        Mock.fireNet('qb-drugs:client:cornerselling', 1)
        Mock.fireNet('qb-drugs:client:refreshAvailableDrugs', 1, {})
        assert_eq(busyCalls(), 'cornerselling=true cornerselling=false')
        assert_eq(#stateWrites, 0)
    end)
end)

describe('pfm-smallresources harness', function()
    it('fitting a harness holds the lock for the bar; a cancelled bar releases it too', function()
        inVehicle = true
        Mock.fireNet('seatbelt:client:UseHarness', 1, { slot = 3, info = { uses = 5 } })
        assert_eq(busyCalls(), 'harness=true')
        lastBar().cancel()                                     -- used to leave the flag held
        assert_eq(busyCalls(), 'harness=true harness=false')
        Mock.fireNet('seatbelt:client:UseHarness', 1, { slot = 3, info = { uses = 5 } })
        lastBar().finish()
        assert_eq(busyCalls(), 'harness=true harness=false harness=true harness=false')
        assert_eq(toServer[#toServer].name, 'equip:harness')
        assert_eq(#stateWrites, 0)
    end)
end)

describe('pfm-diving', function()
    it('selling coral holds the lock while the buyer checks the pockets', function()
        callbackResults['qb-diving:server:GetDivingConfig'] = { diving.Config.CoralLocations, 1 }
        divingLoaded()
        assert_true(#targetOptions >= 1, 'a seller was set up')
        targetOptions[1].options[1].action()
        assert_eq(busyCalls(), 'diving=true')
        lastBar().finish()
        assert_eq(busyCalls(), 'diving=true diving=false')
        assert_eq(toServer[#toServer - 1].name, 'qb-diving:server:SellCorals')
        targetOptions[1].options[1].action()
        lastBar().cancel()
        assert_eq(busyCalls(), 'diving=true diving=false diving=true diving=false')
        assert_eq(#stateWrites, 0)
    end)
end)
