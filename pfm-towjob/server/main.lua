local QBCore = exports['pfm-core']:GetCoreObject()
local PaymentTax = 15
local Bail = {}
local Sessions = {}

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

AddEventHandler('playerDropped', function()
    Sessions[source] = nil
end)

-- Mission vehicles already towed once: [netId] = true. A car can be hooked once.
local hookedVehicles = {}

local function nearCoords(a, c, range)
    return #(vector3(a.x, a.y, a.z) - vector3(c.x, c.y, c.z)) <= range
end

-- The towed vehicle must be one of the mission's tow-spot cars, near its spot when hooked.
local function IsMissionVehicle(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    local model, pos = GetEntityModel(vehicle), GetEntityCoords(vehicle)
    for _, spot in pairs(Config.Locations['towspots']) do
        -- compared as unsigned 32-bit hashes (model hashes can come back signed or unsigned)
        if (model & 0xFFFFFFFF) == (joaat(spot.model) & 0xFFFFFFFF) and nearCoords(pos, spot.coords, 40.0) then return true end
    end
    return false
end

RegisterNetEvent('qb-tow:server:DoBail', function(bool, vehInfo)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if bool then
        -- only the configured tow trucks can be rented (vehInfo is passed on to the spawn)
        if type(vehInfo) ~= 'string' or not Config.Vehicles[vehInfo] then return end
        if Bail[Player.PlayerData.citizenid] then return end -- one truck at a time
        -- the deposit goes through the bank ledger; its refund later uses the same bail id
        local bailId = PFPayout.NewId()
        local paidFrom = PFPayout.Charge(Player, { 'cash', 'bank' }, Config.BailPrice,
            { key = ('pfm-towjob:bail:%s'):format(bailId), reason = 'tow-paid-bail' })
        if paidFrom then
            Bail[Player.PlayerData.citizenid] = { amount = Config.BailPrice, id = bailId }
            TriggerClientEvent('QBCore:Notify', src, Lang:t(paidFrom == 'cash' and 'success.paid_with_cash' or 'success.paid_with_bank', { value = Config.BailPrice }), 'success')
            TriggerClientEvent('qb-tow:client:SpawnVehicle', src, vehInfo)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_deposit', { value = Config.BailPrice }), 'error')
        end
    else
        -- the deposit comes back when the truck is returned at the depot
        if not nearCoords(GetEntityCoords(GetPlayerPed(src)), Config.Locations['vehicle'].coords, 25.0) then return end
        local bail = Bail[Player.PlayerData.citizenid]
        if bail ~= nil then
            if not PFPayout.Pay(Player, 'bank', bail.amount, { key = ('pfm-towjob:bail:%s:refund'):format(bail.id), reason = 'tow-bail-paid', kind = 'refund' }) then return end
            Bail[Player.PlayerData.citizenid] = nil
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.refund_to_cash', { value = Config.BailPrice }), 'success')
        end
    end
end)

RegisterNetEvent('qb-tow:server:nano', function(vehNetID)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local targetVehicle = NetworkGetEntityFromNetworkId(vehNetID)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerVehicle = GetVehiclePedIsIn(playerPed, true)
    local playerVehicleCoords = GetEntityCoords(playerVehicle)
    local targetVehicleCoords = GetEntityCoords(targetVehicle)
    local dist = #(playerVehicleCoords - targetVehicleCoords)
    if Player.PlayerData.job.name ~= 'tow' or dist > 11.0 then
        return DropPlayer(src, Lang:t('info.skick'))
    end
    -- Only a mission car counts (it used to accept any vehicle id, including the player's own truck),
    -- one hook at a time, and each car once.
    Sessions[src] = Sessions[src] or { id = PFPayout.NewId(), drops = 0 }
    if Sessions[src].pendingHook then return end
    if targetVehicle == playerVehicle or hookedVehicles[vehNetID] or not IsMissionVehicle(targetVehicle) then return end
    hookedVehicles[vehNetID] = true
    Sessions[src].pendingHook = vehNetID
    Sessions[src].hookTime = os.time()
end)

-- Drop-off confirmation: the hooked car must really be at the drop-off. The server checks it there and
-- removes it; only then the drop counts (and the cryptostick roll happens, no longer on hooking).
RegisterNetEvent('qb-tow:server:vehicleDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= 'tow' then return end
    local session = Sessions[src]
    if not session or not session.pendingHook then return end
    local dropoff = Config.Locations['dropoff'].coords
    if not nearCoords(GetEntityCoords(GetPlayerPed(src)), dropoff, 30.0) then return end
    if (os.time() - (session.hookTime or 0)) < (Config.MinDeliverySeconds or 15) then return end
    local vehicle = NetworkGetEntityFromNetworkId(session.pendingHook)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
    if not nearCoords(GetEntityCoords(vehicle), dropoff, 30.0) then return end
    DeleteEntity(vehicle)
    session.pendingHook = nil
    if session.drops < (Config.MaxDropsPerSession or 50) then
        session.drops = session.drops + 1
        if math.random(1, 100) < 26 then
            exports['pfm-inventory']:AddItem(src, 'cryptostick', 1, false, false, 'qb-tow:server:vehicleDropped')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['cryptostick'], 'add')
        end
    end
end)

RegisterNetEvent('qb-tow:server:11101110', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    if Player.PlayerData.job.name ~= 'tow' or #(playerCoords - vector3(Config.Locations['main'].coords.x, Config.Locations['main'].coords.y, Config.Locations['main'].coords.z)) > 6.0 then
        return DropPlayer(src, Lang:t('info.skick'))
    end
    -- Server-tracked drop count only; the client-sent value is ignored
    local session = Sessions[src]
    local drops = session and session.drops or 0
    if drops <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_work_done'), 'error')
        return
    end
    local price = 0
    for i = 1, drops do
        price = price + applyStreakBonus(i - 1, math.random(150, 170))
    end
    local bonus = 0
    local DropPrice = math.random(150, 170)
    if drops > 20 then
        bonus = math.ceil((DropPrice / 10) * 12)
    elseif drops > 15 then
        bonus = math.ceil((DropPrice / 10) * 10)
    elseif drops > 10 then
        bonus = math.ceil((DropPrice / 10) * 7)
    elseif drops > 5 then
        bonus = math.ceil((DropPrice / 10) * 5)
    end
    price = price + bonus
    local taxAmount = math.ceil((price / 100) * PaymentTax)
    local payment = price - taxAmount
    -- paid through the bank ledger once per tow session; the session (and its drops) stays if it fails
    if not PFPayout.Pay(Player, 'bank', payment, { key = ('pfm-towjob:%s:salary'):format(session.id), reason = 'tow-salary' }) then return end
    Sessions[src] = nil
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.you_earned', { value = payment }), 'success')
end)

QBCore.Commands.Add('npc', Lang:t('info.toggle_npc'), {}, false, function(source)
    TriggerClientEvent('jobs:client:ToggleNpc', source)
end)

QBCore.Commands.Add('tow', Lang:t('info.tow'), {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if Player.PlayerData.job.name == 'tow' or Player.PlayerData.job.name == 'mechanic' then
        TriggerClientEvent('qb-tow:client:TowVehicle', source)
    end
end)
