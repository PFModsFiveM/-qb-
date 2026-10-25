-- A tackle reaches only a player right next to the tackler (the client used to name any player id,
-- anywhere on the map, and knock them over).
local TACKLE_RANGE = 3.0

RegisterNetEvent('tackle:server:TacklePlayer', function(playerId)
    local src = source
    playerId = tonumber(playerId)
    if not playerId or playerId == src or not exports['pfm-core']:GetPlayer(playerId) then return end
    local ped, targetPed = GetPlayerPed(src), GetPlayerPed(playerId)
    if not ped or ped == 0 or not targetPed or targetPed == 0 then return end
    if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) > TACKLE_RANGE then return end
    TriggerClientEvent('tackle:client:GetTackled', playerId)
end)

QBCore.Commands.Add('id', 'Check Your ID #', {}, false, function(source)
    TriggerClientEvent('QBCore:Notify', source, 'ID: ' .. source)
end)

QBCore.Functions.CreateUseableItem('harness', function(source, item)
    TriggerClientEvent('seatbelt:client:UseHarness', source, item)
end)

-- The harness events name a slot, which must hold a harness (any item's info used to be edited, and
-- a missing slot crashed the handler).
local function harnessInSlot(Player, slot)
    slot = tonumber(slot)
    local item = slot and Player.PlayerData.items[slot]
    if type(item) ~= 'table' or item.name ~= 'harness' then return nil end
    if type(item.info) ~= 'table' then item.info = {} end
    return item, slot
end

RegisterNetEvent('equip:harness', function(item)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(item) ~= 'table' then return end
    local harness, slot = harnessInSlot(Player, item.slot)
    if not harness then return end
    if not harness.info.uses then
        harness.info.uses = Config.HarnessUses - 1
        Player.SetInventory(Player.PlayerData.items)
    elseif harness.info.uses == 1 then
        exports['pfm-inventory']:RemoveItem(src, 'harness', 1, slot, 'equip:harness')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['harness'], 'remove')
    else
        harness.info.uses -= 1
        Player.SetInventory(Player.PlayerData.items)
    end
end)

RegisterNetEvent('seatbelt:DoHarnessDamage', function(hp, data)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(data) ~= 'table' then return end
    local harness, slot = harnessInSlot(Player, data.slot)
    if not harness then return end
    if hp == 0 then
        exports['pfm-inventory']:RemoveItem(src, 'harness', 1, slot, 'seatbelt:DoHarnessDamage')
    else
        harness.info.uses = (tonumber(harness.info.uses) or Config.HarnessUses) - 1
        Player.SetInventory(Player.PlayerData.items)
    end
end)

RegisterNetEvent('qb-carwash:server:washCar', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)

    if not Player then return end

    if PFPayout.Charge(Player, { 'cash', 'bank' }, Config.CarWash.defaultPrice, {
        key = ('pfm-smallresources:carwash:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId()), kind = 'purchase', reason = 'Car wash',
    }) then
        TriggerClientEvent('qb-carwash:client:washCar', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.dont_have_enough_money'), 'error')
    end
end)

QBCore.Functions.CreateCallback('smallresources:server:GetCurrentPlayers', function(_, cb)
    cb(#GetPlayers())
end)
