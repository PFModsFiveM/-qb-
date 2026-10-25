-- Interaction with persistent world objects. The server spawns the entities and decides everything;
-- this only offers the actions to the player and asks the server.
local Known = {} -- [id] = { netId, coords, state }

local function targetOptions(id)
    return {
        options = {
            { icon = 'fas fa-box-open', label = 'Inspect delivery', action = function() TriggerServerEvent('pfm-worldobjects:server:open', id) end },
            { icon = 'fas fa-dolly', label = 'Unpack into stock', action = function() TriggerServerEvent('pfm-worldobjects:server:unpack', id) end },
            { icon = 'fas fa-arrows-alt', label = 'Move in front of me', action = function() TriggerServerEvent('pfm-worldobjects:server:move', id) end },
        },
        distance = (Config.WorldObjects and Config.WorldObjects.InteractDistance) or 3.0,
    }
end

local function attachTarget(id, info)
    -- fixtures (installed equipment) have no delivery actions
    if info.kind == 'fixture' then return end
    if not info.netId or GetResourceState('pfm-target') ~= 'started' then return end
    CreateThread(function()
        local tries = 0
        while not NetworkDoesNetworkIdExist(info.netId) and tries < 50 do
            Wait(100)
            tries = tries + 1
        end
        if not NetworkDoesNetworkIdExist(info.netId) then return end
        local entity = NetToObj(info.netId)
        if entity and entity ~= 0 then
            pcall(function() exports['pfm-target']:AddTargetEntity(entity, targetOptions(id)) end)
        end
    end)
end

RegisterNetEvent('pfm-worldobjects:client:upsert', function(obj)
    if type(obj) ~= 'table' or not obj.id then return end
    Known[obj.id] = obj
    attachTarget(obj.id, obj)
end)

RegisterNetEvent('pfm-worldobjects:client:all', function(list)
    for _, obj in ipairs(list or {}) do
        Known[obj.id] = obj
        attachTarget(obj.id, obj)
    end
end)

RegisterNetEvent('pfm-worldobjects:client:removed', function(id)
    Known[id] = nil
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('pfm-worldobjects:server:sync')
end)

AddEventHandler('onClientResourceStart', function(name)
    if name == GetCurrentResourceName() then TriggerServerEvent('pfm-worldobjects:server:sync') end
end)
