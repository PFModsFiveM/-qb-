local Objects = {}

local function CreateObjectId()
    if Objects then
        local objectId = math.random(10000, 99999)
        while Objects[objectId] do
            objectId = math.random(10000, 99999)
        end
        return objectId
    else
        local objectId = math.random(10000, 99999)
        return objectId
    end
end

local function IsOnDutyLeo(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

RegisterNetEvent('police:server:spawnObject', function(type)
    local src = source
    if not IsOnDutyLeo(src) then return end
    if not Config.Objects[type] then return end
    local objectId = CreateObjectId()
    Objects[objectId] = type
    TriggerClientEvent('police:client:spawnObject', src, objectId, type, src)
end)

RegisterNetEvent('police:server:deleteObject', function(objectId)
    local src = source
    if not IsOnDutyLeo(src) then return end
    if not Objects[objectId] then return end
    Objects[objectId] = nil
    TriggerClientEvent('police:client:removeObject', -1, objectId)
end)

RegisterNetEvent('police:server:SyncSpikes', function(table)
    local src = source
    if not IsOnDutyLeo(src) then return end
    if type(table) ~= 'table' then return end
    local count = 0
    for _ in pairs(table) do
        count += 1
        if count > Config.MaxSpikes then return end
    end
    TriggerClientEvent('police:client:SyncSpikes', -1, table)
end)
