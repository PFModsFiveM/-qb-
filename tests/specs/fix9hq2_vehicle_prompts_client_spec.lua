-- Client side of the vehicle sales fixes. pfm-vehicleshop: the "Accept and pay" prompt answers the
-- offer it was shown (its id goes with the answer, so a replaced offer is not accepted by the old
-- click) and shows a loan that comes with a transferred car. pfm-vehiclesales: the car at the lot is
-- removed only after the server listed it or paid for it (a refused fleet or financed car used to
-- vanish anyway), and the reason the server gives for a car that cannot be sold is shown.
load_resource('tests/lua/fivem_mocks.lua')

-- Client scripts run in their own environment; any native not listed answers false (Is*/Has*/Does*)
-- or 0. Threads run as coroutines and Wait yields.
local function clientEnv(overrides)
    local env = { threads = {}, net = {}, events = {}, nuiCallbacks = {}, server = {}, menus = {}, notes = {}, removed = {}, callbacks = {} }
    env.CreateThread = function(fn)
        local co = coroutine.create(fn)
        env.threads[#env.threads + 1] = co
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 2) end
    end
    env.Wait = function() coroutine.yield() end
    env.RegisterNetEvent = function(name, fn) env.net[name] = fn end
    env.AddEventHandler = function(name, fn) env.events[name] = fn end
    env.RegisterNUICallback = function(name, fn) env.nuiCallbacks[name] = fn end
    env.TriggerServerEvent = function(name, ...) env.server[#env.server + 1] = { name = name, args = { ... } } end
    local zone = { onPlayerInOut = function() end, destroy = function() end }
    local zoneClass = { Create = function() return zone end }
    env.PolyZone, env.CircleZone, env.BoxZone = zoneClass, zoneClass, zoneClass
    local core = { Functions = {
        GetPlayerData = function() return { job = {}, charinfo = {} } end,
        Notify = function(text) env.notes[#env.notes + 1] = text end,
        TriggerCallback = function(name, cb, ...) env.callbacks[name](cb, ...) end,
        GetPlate = function() return 'ABC123' end,
        DeleteVehicle = function(veh) env.removed[#env.removed + 1] = veh end,
        GetVehicleProperties = function() return { color = 1 } end,
        SetVehicleProperties = function() end,
    } }
    local quiet = setmetatable({}, { __index = function() return function() end end })
    env.exports = setmetatable({}, { __index = function(_, res)
        if res == 'pfm-core' then return { GetCoreObject = function() return core end, GetShared = function() return {} end, DrawText = function() end, HideText = function() end } end
        if res == 'pfm-menu' then return { openMenu = function(_, menu) env.menus[#env.menus + 1] = menu end } end
        return quiet
    end })
    for k, v in pairs(overrides or {}) do env[k] = v end
    return setmetatable(env, { __index = function(_, k)
        local g = _G[k]
        if g ~= nil then return g end
        if type(k) == 'string' and (k:match('^Is') or k:match('^Has') or k:match('^Does') or k:match('^NetworkIs')) then
            return function() return false end
        end
        return function() return 0 end
    end })
end

local function loadInto(env, path)
    assert(load(__readfile(path), '@' .. path, 't', env))()
end

-- runs a handler that waits (fades, timers) to its end
local function run(fn, ...)
    local args = { ... }
    local co = coroutine.create(function() fn(table.unpack(args)) end)
    for _ = 1, 1000 do
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 2) end
        if coroutine.status(co) == 'dead' then return end
    end
    error('handler did not finish')
end

describe('pfm-vehicleshop: the purchase prompt', function()
    local env = clientEnv({ Config = {} })
    loadInto(env, 'pfm-vehicleshop/config.lua')
    loadInto(env, 'pfm-vehicleshop/client.lua')

    it('both answers carry the id of the offer shown, not a bare true/false', function()
        env.menus = {}
        env.net['qb-vehicleshop:client:confirmPurchase']({ id = 'offer-17', label = 'Cognoscenti', amount = 108000, tax = 8000, seller = 'Sam', kind = 'dealer' })
        local menu = env.menus[1]
        assert_true(menu ~= nil, 'the prompt opened')
        local accept, decline = menu[2].params, menu[3].params
        assert_eq(accept.event, 'qb-vehicleshop:server:answerPurchase')
        assert_true(accept.isServer)
        assert_eq(type(accept.args), 'table')
        assert_true(accept.args.accept == true)
        assert_eq(accept.args.id, 'offer-17')
        assert_true(decline.args.accept == false)
        assert_eq(decline.args.id, 'offer-17')
    end)
    it('a transferred car that still has a loan says so', function()
        env.menus = {}
        env.net['qb-vehicleshop:client:confirmPurchase']({ id = 'offer-18', label = 'Blista (MYCAR1)', amount = 5000, seller = 'Sam', kind = 'transfer', loan = 6000 })
        assert_true(env.menus[1][1].txt:find('6000', 1, true) ~= nil)
    end)
end)

describe('pfm-vehiclesales: the car leaves only when the server says so', function()
    local VEH = 900
    local env = clientEnv({
        Config = {},
        PlayerPedId = function() return 7 end,
        IsPedInAnyVehicle = function() return true end,
        GetVehiclePedIsIn = function() return VEH end,
        GetVehiclePedIsUsing = function() return VEH end,
        GetEntityModel = function() return 123 end,
        GetVehicleNumberPlateText = function() return 'ABC123' end,
    })
    loadInto(env, 'pfm-vehiclesales/config.lua')
    loadInto(env, 'pfm-vehiclesales/client/main.lua')
    local owner = { true, 0, nil }
    env.callbacks['qb-occasions:server:checkVehicleOwner'] = function(cb) cb(owner[1], owner[2], owner[3]) end
    env.callbacks['qb-vehiclesales:server:CheckModelName'] = function(cb) cb('sultan') end
    local function reset() env.server, env.removed, env.notes = {}, {}, {} owner = { true, 0, nil } end

    it('selling back asks the server and keeps the car until it has paid', function()
        reset()
        env.net['qb-occasions:client:SellBackCar']()
        assert_eq(#env.server, 1)
        assert_eq(env.server[1].name, 'qb-occasions:server:sellVehicleBack')
        assert_eq(#env.removed, 0, 'not removed before the server answered')
        env.net['qb-occasions:client:soldBack'](10000)
        assert_eq(env.removed[1], VEH)
    end)
    it('a car the server says cannot be sold (a fleet car) is not offered and stays', function()
        reset()
        owner = { true, 0, 'error.fleet_vehicle' }
        env.net['qb-occasions:client:SellBackCar']()
        assert_eq(#env.server, 0)
        assert_eq(env.notes[1], 'error.fleet_vehicle')
        env.net['qb-vehiclesales:client:SellVehicle']()
        assert_eq(env.notes[2], 'error.fleet_vehicle')
        assert_eq(#env.removed, 0)
    end)
    it('listing sends the contract and removes the car only once the server listed it', function()
        reset()
        env.nuiCallbacks['sellVehicle']({ price = 9000, desc = 'nice' }, function() end)
        assert_eq(#env.server, 1)
        assert_eq(env.server[1].name, 'qb-occasions:server:sellVehicle')
        assert_eq(env.server[1].args[1], 9000)
        assert_eq(#env.removed, 0, 'a refused listing keeps the car')
        run(env.net['qb-occasions:client:vehicleListed'], 9000)
        assert_eq(env.removed[1], VEH)
    end)
end)
